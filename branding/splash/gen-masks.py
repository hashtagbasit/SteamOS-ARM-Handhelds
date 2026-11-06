#!/usr/bin/env python3
"""Turn the logo into the coverage masks zaviya-splash.c draws from.

Needs rsvg-convert and Pillow. Run after changing the logo, commit logo_masks.h.
"""
import re
import subprocess
from io import BytesIO
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
SVG = (HERE.parent / "logo/zaviya-logo-tagline-white.svg").read_text()
W, H = 1000, 802
NAMES = ["frame", "gold", "name", "tag"]

head = SVG[:SVG.index(">") + 1]
groups = re.findall(r"<g [^>]*>.*?</g>", SVG, re.S)
paths = []
for g in groups:
    open_tag = g[:g.index(">") + 1]
    paths += [open_tag + p + "</g>" for p in re.findall(r"<path [^>]*/>", g)]
assert len(paths) == len(NAMES), len(paths)


def mask(path):
    svg = head + re.sub(r'fill="#[0-9A-Fa-f]+"', 'fill="#FFFFFF"', path) + "</svg>"
    png = subprocess.run(["rsvg-convert", "-w", str(W), "-h", str(H)],
                         input=svg.encode(), capture_output=True, check=True).stdout
    return Image.open(BytesIO(png)).convert("RGBA").getchannel("A")


def rle(data):
    out = bytearray()
    i = 0
    while i < len(data):
        j = i
        while j < len(data) and data[j] == data[i] and j - i < 65535:
            j += 1
        out += bytes(((j - i) & 255, (j - i) >> 8, data[i]))
        i = j
    return out


with open(HERE / "logo_masks.h", "w") as f:
    f.write(f"/* Written by gen-masks.py. Runs of (count low, count high, value). */\n")
    f.write(f"#define MASK_W {W}\n#define MASK_H {H}\n")
    for name, path in zip(NAMES, paths):
        r = rle(mask(path).tobytes())
        f.write(f"static const unsigned char rle_{name}[{len(r)}] = {{\n")
        for i in range(0, len(r), 24):
            f.write(",".join(map(str, r[i:i + 24])) + ",\n")
        f.write("};\n")
