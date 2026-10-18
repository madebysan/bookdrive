#!/usr/bin/env python3
"""Consistency checks for the screenshot pipeline.

  provenance.py source <run-dir> [--allow-dirty] [--allow-older]
      Record which code is being captured (commit, version, build) in <run-dir>/source.json.
      Fails when app or harness code has uncommitted changes, or when the code is older than
      the version live on the App Store.
  provenance.py built <run-dir> <app-path>
      Fail unless the built app reports the version and build recorded by `source`.
  provenance.py compare <approved-dir> <new-dir>
      List which screenshots changed against the last approved set.
  provenance.py record <run-dir> <screenshots-dir> <provenance-json>
      Write the provenance file (source, simulator, checksums) that upload lanes verify.
  provenance.py verify <screenshots-dir> <provenance-json>
      Fail unless the PNGs are exactly the ones the pipeline recorded.
"""

import hashlib
import json
import plistlib
import re
import subprocess
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image, ImageChops

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
CONFIG = json.loads((HERE / "slots.json").read_text())
APP = CONFIG["app"]
# "ios" (default) or "macos": Mac apps are looked up in the Mac App Store and keep Info.plist under Contents/.
PLATFORM = CONFIG.get("platform", "ios")
PBXPROJ = PROJECT / APP["version_project"] / "project.pbxproj"
# Uncommitted changes here change what the simulator shows, so a capture refuses them.
CAPTURE_INPUTS = APP["capture_inputs"]
NOT_LISTED = "not on the App Store"


def git(*args: str) -> str:
    return subprocess.run(["git", "-C", str(PROJECT), *args], check=True, capture_output=True, text=True).stdout.rstrip()


def app_target_setting(name: str) -> str | None:
    """Ask xcodebuild for the app target's own value (used when test targets differ from the app)."""
    output = subprocess.run(
        ["xcodebuild", "-project", str(PROJECT / APP["version_project"]), "-scheme", APP["scheme"],
         "-configuration", APP["configuration"], "-showBuildSettings"],
        capture_output=True, text=True).stdout
    for block in output.split("Build settings for action")[1:]:
        if re.search(rf"^\s*PRODUCT_NAME = {re.escape(APP['product'])}$", block, re.M):
            found = re.search(rf"^\s*{name} = (.+)$", block, re.M)
            return found.group(1).strip() if found else None
    return None


def build_setting(name: str) -> str:
    values = set(re.findall(rf"\b{name} = ([^;]+);", PBXPROJ.read_text()))
    if len(values) == 1:
        return values.pop().strip('"')
    value = app_target_setting(name)
    if value is None:
        sys.exit(f"Expected one {name} in {PBXPROJ.name}, found {sorted(values) or 'none'}, "
                 f"and the {APP['product']} target's own value couldn't be read")
    return value


def version_key(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in re.findall(r"\d+", version))


def live_version(bundle_id: str) -> str | None:
    url = f"https://itunes.apple.com/lookup?bundleId={bundle_id}&country=us"
    if PLATFORM == "macos":
        url += "&entity=macSoftware"
    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            results = json.load(response).get("results", [])
    except OSError as error:
        print(f"warning: App Store lookup failed ({error}); live version not checked")
        return None
    return results[0]["version"] if results else NOT_LISTED


def source(run_dir: Path, allow_dirty: bool, allow_older: bool) -> None:
    dirty = [line[3:] for line in git("status", "--porcelain", "--", *CAPTURE_INPUTS).splitlines()]
    captions_dirty = bool(git("status", "--porcelain", "--", str(HERE.relative_to(PROJECT))))
    bundle_id = APP["bundle_id"]
    record = {
        "commit": git("rev-parse", "HEAD"),
        "branch": git("rev-parse", "--abbrev-ref", "HEAD"),
        "version": build_setting("MARKETING_VERSION"),
        "build": build_setting("CURRENT_PROJECT_VERSION"),
        "bundle_id": bundle_id,
        "uncommitted_capture_inputs": dirty,
        "uncommitted_captions_or_template": captions_dirty,
        "app_store_version": live_version(bundle_id),
        "checked_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    live = record["app_store_version"]
    listed = live not in (None, NOT_LISTED)
    store = f"App Store has {live}" if listed else ("app is not on the App Store yet" if live else "App Store version unknown")
    print(f"Capturing {record['version']} ({record['build']}) from {record['branch']} @ {record['commit'][:7]}; {store}")
    problems = []
    if dirty and not allow_dirty:
        problems.append("uncommitted app or harness changes: " + ", ".join(dirty)
                        + ". Commit them, or pass --allow-dirty for a draft run.")
    if dirty and allow_dirty:
        print("warning: capturing uncommitted changes (--allow-dirty): " + ", ".join(dirty))
    if listed and version_key(record["version"]) < version_key(live) and not allow_older:
        problems.append(f"this code is {record['version']}, older than the live {live}. "
                        "Check out the release you are shipping, or pass --allow-older.")
    if listed and version_key(record["version"]) > version_key(live):
        print(f"note: {record['version']} is not released yet; screenshots show unreleased UI")
    (run_dir / "source.json").write_text(json.dumps(record, indent=2) + "\n")
    if problems:
        sys.exit("Stopped before capture:\n  - " + "\n  - ".join(problems))


def built(run_dir: Path, app_path: Path) -> None:
    expected = json.loads((run_dir / "source.json").read_text())
    plist = app_path / "Contents" / "Info.plist" if PLATFORM == "macos" else app_path / "Info.plist"
    with plist.open("rb") as handle:
        info = plistlib.load(handle)
    actual = (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion"))
    if actual != (expected["version"], expected["build"]):
        sys.exit(f"Built app reports {actual}, expected {(expected['version'], expected['build'])}: {app_path}")
    print(f"Built app is {actual[0]} ({actual[1]})")


def changed_fraction(old: Path, new: Path) -> float:
    with Image.open(old) as a, Image.open(new) as b:
        if a.size != b.size:
            return 1.0
        small = (a.width // 4, a.height // 4)
        difference = ImageChops.difference(a.convert("RGB").resize(small), b.convert("RGB").resize(small))
        # Fraction of pixels that moved by more than compression noise.
        mask = difference.convert("L").point(lambda value: 255 if value > 24 else 0)
        return mask.histogram()[255] / (small[0] * small[1])


def compare(approved: Path, new: Path) -> None:
    old_files = {p.name: p for p in approved.glob("*.png")}
    new_files = {p.name: p for p in new.glob("*.png")}
    print("Compared with the last approved set:")
    for name in sorted(old_files | new_files):
        if name not in old_files:
            print(f"  {name}: new slot")
        elif name not in new_files:
            print(f"  {name}: removed")
        else:
            fraction = changed_fraction(old_files[name], new_files[name])
            print(f"  {name}: {'unchanged' if fraction < 0.001 else f'changed ({fraction:.1%} of pixels)'}")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def record(run_dir: Path, screenshots: Path, output: Path) -> None:
    provenance = json.loads((run_dir / "source.json").read_text())
    capture_info = run_dir / "capture.json"
    if capture_info.exists():
        provenance.update(json.loads(capture_info.read_text()))
    provenance["run"] = run_dir.name
    provenance["screenshots"] = {p.name: sha256(p) for p in sorted(screenshots.glob("*.png"))}
    output.write_text(json.dumps(provenance, indent=2) + "\n")
    print(f"Recorded provenance in {output.relative_to(PROJECT)}")


def verify(screenshots: Path, provenance_path: Path) -> None:
    if not provenance_path.exists():
        sys.exit(f"No {provenance_path.name}; run `fastlane ios generate_screenshots` first.")
    expected = json.loads(provenance_path.read_text())["screenshots"]
    actual = {p.name: sha256(p) for p in sorted(screenshots.glob("*.png"))}
    if actual != expected:
        mismatched = sorted(name for name in expected.keys() | actual.keys() if expected.get(name) != actual.get(name))
        sys.exit(f"{screenshots} doesn't match {provenance_path.name} ({', '.join(mismatched)}). "
                 "Only upload screenshots made by `fastlane ios generate_screenshots`.")
    print(f"{len(actual)} screenshots match the pipeline's provenance record")


def main(argv: list[str]) -> None:
    flags = {arg for arg in argv if arg.startswith("--")}
    args = [arg for arg in argv if not arg.startswith("--")]
    commands = {
        "source": lambda: source(Path(args[1]), "--allow-dirty" in flags, "--allow-older" in flags),
        "built": lambda: built(Path(args[1]), Path(args[2])),
        "compare": lambda: compare(Path(args[1]), Path(args[2])),
        "record": lambda: record(Path(args[1]), Path(args[2]), Path(args[3])),
        "verify": lambda: verify(Path(args[1]), Path(args[2])),
    }
    if not args or args[0] not in commands:
        sys.exit(__doc__)
    commands[args[0]]()


if __name__ == "__main__":
    main(sys.argv[1:])
