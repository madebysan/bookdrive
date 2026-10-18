#!/usr/bin/env python3
"""Frame exported simulator captures into App Store screenshots.

Usage: frame.py <attachments-dir> <output-dir>

<attachments-dir> is the output of `xcrun xcresulttool export attachments`
(it holds manifest.json). Each slot in slots.json names the attachment it uses;
the theme block sets colours and fonts. Renders frame.html with headless Chrome
at the canvas size and writes opaque PNGs. Shared by every app; edit slots.json, not this.
"""

import html
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from string import Template

from PIL import Image

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
CHROME = os.environ.get("CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")


def load_captures(attachments_dir: Path) -> dict[str, Path]:
    manifest = json.loads((attachments_dir / "manifest.json").read_text())
    captures: dict[str, Path] = {}
    for test in manifest:
        for attachment in test["attachments"]:
            # Exported names look like "<name>_0_<UUID>.png".
            name = re.sub(r"_\d+_[0-9A-F-]{36}\.png$", "", attachment["suggestedHumanReadableName"])
            captures[name] = attachments_dir / attachment["exportedFileName"]
    return captures


def caption_html(text: str) -> str:
    """Escape caption text; *word* becomes the accent colour."""
    return re.sub(r"\*(.+?)\*", r"<em>\1</em>", html.escape(text))


def font_uri(path: str) -> str:
    font = Path(path) if Path(path).is_absolute() else PROJECT / path
    if not font.exists():
        sys.exit(f"Font not found: {font}")
    return font.as_uri()


def render(page: Path, output: Path, width: int, height: int) -> None:
    subprocess.run(
        [CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
         "--allow-file-access-from-files", "--virtual-time-budget=3000",
         f"--window-size={width},{height}", f"--screenshot={output}", page.as_uri()],
        check=True, capture_output=True,
    )


def main(attachments_dir: Path, output_dir: Path) -> None:
    config = json.loads((HERE / "slots.json").read_text())
    theme = config["theme"]
    width, height = config.get("canvas", {}).get("width"), config.get("canvas", {}).get("height")
    template = Template((HERE / "frame.html").read_text())
    captures = load_captures(attachments_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as scratch:
        for slot in config["slots"]:
            capture = captures.get(slot["capture"])
            if capture is None:
                sys.exit(f"Missing capture '{slot['capture']}' for {slot['file']}; found {sorted(captures)}")
            if slot.get("frame", True) is False:
                # Unframed: the capture itself, for a README or a Mac window shot. Opaque, original size.
                with Image.open(capture) as image:
                    image.convert("RGB").save(output_dir / slot["file"], optimize=True)
                print(f"copied {slot['file']} <- {slot['capture']} (unframed)")
                continue
            with Image.open(capture) as image:
                capture_w, capture_h = image.size
            page = Path(scratch) / f"{slot['file']}.html"
            page.write_text(template.substitute(
                canvas_w=width, canvas_h=height, capture_w=capture_w, capture_h=capture_h,
                capture=capture.resolve().as_uri(),
                bg_top=theme["background"][0], bg_bottom=theme["background"][1], glow=theme["glow"],
                text=theme["text"], secondary=theme["secondary"], accent=theme["accent"],
                kicker_color=theme["kicker"],
                heading_font=font_uri(theme["heading_font"]), heading_weight=theme["heading_weight"],
                kicker_font=font_uri(theme["kicker_font"]), kicker_weight=theme["kicker_weight"],
                kicker=html.escape(slot["kicker"]),
                headline=caption_html(slot["headline"]),
                sub=caption_html(slot["sub"]),
            ))
            rendered = Path(scratch) / slot["file"]
            render(page, rendered, width, height)
            with Image.open(rendered) as image:
                if image.size != (width, height):
                    sys.exit(f"{slot['file']}: rendered {image.size}, expected {(width, height)}")
                # App Store Connect rejects screenshots with an alpha channel.
                image.convert("RGB").save(output_dir / slot["file"], optimize=True)
            print(f"framed {slot['file']} <- {slot['capture']}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(Path(sys.argv[1]), Path(sys.argv[2]))
