#!/usr/bin/env python3
"""Compose the README hero (assets/screenshot.png) from the latest screenshot capture.

Usage: scripts/readme-hero.py

Run `fastlane ios generate_screenshots` first. This reads the unframed simulator captures
of that run (build/store-screenshots/run-*/raw), so the README shows the same demo library
as the App Store set: four phones, library grid, player, genres and the dark list.
"""

import json
import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "assets/screenshot.png"
CAPTURES = ["library", "player", "genres", "list"]
SCALE = 2  # 2560 x 1280, shown at 1280 x 640
BACKGROUND = (244, 234, 210)  # icon cream


def latest_captures() -> dict[str, Path]:
    runs = sorted((ROOT / "build/store-screenshots").glob("run-*/raw/manifest.json"))
    if not runs:
        sys.exit("No capture found; run `fastlane ios generate_screenshots` first.")
    raw = runs[-1].parent
    captures = {}
    for test in json.loads(runs[-1].read_text()):
        for attachment in test["attachments"]:
            name = re.sub(r"_\d+_[0-9A-F-]{36}\.png$", "", attachment["suggestedHumanReadableName"])
            captures[name] = raw / attachment["exportedFileName"]
    missing = [name for name in CAPTURES if name not in captures]
    if missing:
        sys.exit(f"Capture {raw} lacks {missing}")
    print(f"Using {raw.parent.name}")
    return captures


def phone(screen: Image.Image, height: int) -> Image.Image:
    """The capture inside a plain dark bezel with rounded corners."""
    bezel = 9 * SCALE
    screen_h = height - 2 * bezel
    screen_w = round(screen_h * screen.width / screen.height)
    radius = round(screen_w * 0.141)
    body = Image.new("RGBA", (screen_w + 2 * bezel, height), (0, 0, 0, 0))
    ImageDraw.Draw(body).rounded_rectangle((0, 0, body.width - 1, body.height - 1),
                                           radius=radius + bezel, fill=(28, 30, 32, 255))
    resized = screen.convert("RGB").resize((screen_w, screen_h), Image.LANCZOS)
    mask = Image.new("L", resized.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, screen_w - 1, screen_h - 1), radius=radius, fill=255)
    body.paste(resized, (bezel, bezel), mask)
    # Dynamic Island
    island_w, island_h = round(screen_w * 0.286), round(screen_w * 0.084)
    top = bezel + round(screen_w * 0.026)
    ImageDraw.Draw(body).rounded_rectangle(((body.width - island_w) // 2, top, (body.width + island_w) // 2, top + island_h),
                                           radius=island_h // 2, fill=(0, 0, 0, 255))
    return body


def main() -> None:
    captures = latest_captures()
    width, height = 1280 * SCALE, 640 * SCALE
    canvas = Image.new("RGBA", (width, height), BACKGROUND + (255,))
    phones = [phone(Image.open(captures[name]), 548 * SCALE) for name in CAPTURES]
    gap = 44 * SCALE
    total = sum(p.width for p in phones) + gap * (len(phones) - 1)
    x, y = (width - total) // 2, (height - phones[0].height) // 2
    for p in phones:
        shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
        alpha = p.split()[3].point(lambda value: value * 0.35)
        shadow.paste((60, 40, 10, 255), (x, y + 18 * SCALE), alpha)
        canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(22 * SCALE)))
        canvas.alpha_composite(p, (x, y))
        x += p.width + gap
    canvas.convert("RGB").save(OUTPUT, optimize=True)
    print(f"Wrote {OUTPUT.relative_to(ROOT)} ({width}x{height})")


if __name__ == "__main__":
    main()
