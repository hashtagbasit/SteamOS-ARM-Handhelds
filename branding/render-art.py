#!/usr/bin/env python3
"""Wallpaper, icons and the social images, from the logo. Needs rsvg-convert and Pillow."""
import re
import subprocess
from io import BytesIO
from pathlib import Path

from PIL import Image, ImageFilter

HERE = Path(__file__).resolve().parent
LOGO = HERE / "logo"
GOLD = (0xC9, 0xA2, 0x4D)


def svg_image(text, w, h=None):
    args = ["rsvg-convert", "-w", str(w)] + (["-h", str(h)] if h else [])
    png = subprocess.run(args, input=text.encode(), capture_output=True, check=True).stdout
    return Image.open(BytesIO(png)).convert("RGBA")


def logo(name, w):
    return svg_image((LOGO / name).read_text(), w)


def backdrop(w, h):
    """Black, lifted a little behind the middle."""
    small = Image.new("RGB", (64, 36))
    for y in range(36):
        for x in range(64):
            d = (((x - 31.5) / 32) ** 2 + ((y - 17.5) / 18) ** 2) ** 0.5
            v = max(0.0, 1 - d)
            small.putpixel((x, y), (int(7 + 16 * v), int(7 + 15 * v), int(8 + 15 * v)))
    return small.resize((w, h), Image.BICUBIC)


def centred(canvas, img, dy=0):
    canvas.alpha_composite(img, ((canvas.width - img.width) // 2, (canvas.height - img.height) // 2 + dy))


def wallpaper():
    w, h = 3840, 2160
    c = backdrop(w, h).convert("RGBA")
    mark = logo("zaviya-frame-white.svg", 1500)
    # The bar's light on the wall behind it, and the frame set back from it.
    px = mark.load()
    glow = Image.new("L", mark.size, 0)
    gp = glow.load()
    for y in range(mark.height):
        for x in range(mark.width):
            pr, pg, pb, pa = px[x, y]
            if pa and pb < 150:
                gp[x, y] = pa
            elif pa:
                px[x, y] = (46, 46, 50, pa)
    halo = Image.new("RGBA", c.size, GOLD + (0,))
    full = Image.new("L", c.size, 0)
    full.paste(glow, ((w - mark.width) // 2, (h - mark.height) // 2))
    halo.putalpha(full.filter(ImageFilter.GaussianBlur(90)).point(lambda v: min(255, v * 2)))
    c.alpha_composite(halo)
    centred(c, mark)
    c.convert("RGB").save(HERE / "wallpaper/3840x2160.jpg", quality=92, subsampling=0)


def on_black(name, size, frac, out, bg=(10, 10, 11)):
    w, h = size
    c = Image.new("RGBA", size, bg + (255,))
    centred(c, logo(name, int(w * frac)))
    c.convert("RGB").save(out)


def icons():
    src = (LOGO / "zaviya-frame-small-white.svg").read_text()
    head, body = re.match(r"(<svg[^>]*>)(.*)</svg>", src, re.S).groups()
    vb = [float(v) for v in re.search(r'viewBox="([^"]+)"', head).group(1).split()]
    side = max(vb[2], vb[3]) * 1.3
    x, y = vb[0] - (side - vb[2]) / 2, vb[1] - (side - vb[3]) / 2
    square = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{x:.1f} {y:.1f} {side:.1f} {side:.1f}">'
              f'<rect x="{x:.1f}" y="{y:.1f}" width="{side:.1f}" height="{side:.1f}" rx="{side * .2:.1f}" fill="#0E0E10"/>'
              f"{body}</svg>")
    (HERE / "icons/zaviya.svg").write_text(square)
    # The menu button sits on the panel as it is, so no tile behind it.
    bare = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{x:.1f} {y:.1f} {side:.1f} {side:.1f}">{body}</svg>'
    (HERE / "icons/zaviya-mark.svg").write_text(bare)
    svg_image(square, 256).save(HERE / "icons/zaviya-256.png")
    svg_image(square, 32).save(HERE / "social/favicon-32.png")
    (HERE / "social/favicon.svg").write_text(square)
    svg_image(square, 1024).convert("RGB").save(HERE / "social/avatar-1024.png")


wallpaper()
icons()
on_black("zaviya-logo-tagline-white.svg", (1280, 640), 0.5, HERE / "social/github-social-preview-1280x640.png")
on_black("zaviya-logo-white.svg", (960, 540), 0.42, HERE / "social/discord-banner-960x540.png")
