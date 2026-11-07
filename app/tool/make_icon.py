"""Draws the Cabinet CRM app icon (a shaker cabinet front) as PNGs.

    python3 tool/make_icon.py
    dart run flutter_launcher_icons          # then generates every platform size

Outputs assets/icon/icon.png (full icon, 1024px), icon_fg.png (Android adaptive
foreground, transparent) and icon_bg.png (adaptive background).
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

OUT = Path(__file__).resolve().parent.parent / "assets" / "icon"
OUT.mkdir(parents=True, exist_ok=True)

S = 4096          # draw big, downscale for smooth edges
BLUE_TOP = (63, 125, 232)
BLUE_BOT = (29, 78, 178)
CREAM = (247, 243, 234)
CREAM_SHADOW = (214, 206, 190)
PANEL = (232, 226, 212)
NAVY = (24, 48, 92)
OAK = (217, 165, 92)
OAK_DARK = (181, 130, 64)


def gradient(size, top, bottom):
    img = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / (size - 1)
        img.putpixel((0, y), tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return img.resize((size, size))


def rounded_mask(size, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return m


def background(size):
    """Blue rounded square with a soft highlight."""
    bg = gradient(size, BLUE_TOP, BLUE_BOT).convert("RGBA")
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse((-size * 0.2, -size * 0.55, size * 0.9, size * 0.45), fill=(255, 255, 255, 46))
    glow = glow.filter(ImageFilter.GaussianBlur(size * 0.08))
    bg.alpha_composite(glow)
    return bg


def cabinet(size, scale=1.0, offset=(0, 0)):
    """The cabinet front on a transparent layer. scale<1 shrinks it (adaptive icons crop the edges)."""
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    u = size / 1024 * scale
    ox, oy = offset

    def R(x0, y0, x1, y1):
        return (ox + x0 * u, oy + y0 * u, ox + x1 * u, oy + y1 * u)

    # Drop shadow under the whole front
    sh = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle(R(176, 228, 848, 836), radius=28 * u, fill=(0, 0, 0, 90))
    sh = sh.filter(ImageFilter.GaussianBlur(22 * u))
    layer.alpha_composite(sh)

    # Countertop (warm oak slab with a darker front edge)
    d.rounded_rectangle(R(150, 196, 874, 262), radius=18 * u, fill=OAK)
    d.rectangle(R(150, 244, 874, 268), fill=OAK_DARK)

    # Cabinet carcass (cream) with a thin shadow line under the countertop
    d.rounded_rectangle(R(176, 262, 848, 820), radius=26 * u, fill=CREAM)
    d.rectangle(R(176, 262, 848, 290), fill=CREAM_SHADOW)

    # Two shaker doors: outer frame cream, recessed panel slightly darker with an inner shadow edge
    for x0, x1 in ((206, 506), (518, 818)):
        d.rounded_rectangle(R(x0, 318, x1, 790), radius=14 * u, fill=CREAM)
        d.rounded_rectangle(R(x0 + 44, 362, x1 - 44, 746), radius=10 * u, fill=CREAM_SHADOW)
        d.rounded_rectangle(R(x0 + 52, 370, x1 - 44, 746), radius=10 * u, fill=PANEL)
    # Gap between the doors
    d.rectangle(R(506, 318, 518, 790), fill=CREAM_SHADOW)

    # Handles: vertical navy bar pulls near the centre gap
    for x in (470, 554):
        d.rounded_rectangle(R(x - 13, 470, x + 13, 640), radius=13 * u, fill=NAVY)
        d.rounded_rectangle(R(x - 6, 480, x, 630), radius=6 * u, fill=(60, 88, 140))

    # Toe kick
    d.rounded_rectangle(R(206, 800, 818, 836), radius=10 * u, fill=NAVY)
    return layer


def save(img, name, size=1024):
    img.resize((size, size), Image.LANCZOS).save(OUT / name, optimize=True)


# Full icon (iOS, Windows, macOS, Linux, web): background + cabinet, rounded corners.
full = background(S)
full.alpha_composite(cabinet(S))
full.putalpha(rounded_mask(S, int(S * 0.22)))
save(full, "icon.png")

# iOS wants no transparency (it rounds the corners itself).
ios = background(S)
ios.alpha_composite(cabinet(S))
save(ios.convert("RGB"), "icon_ios.png")

# Android adaptive: foreground in the safe zone (inner 66%), background plain gradient.
fg = cabinet(S, scale=0.62, offset=(S * 0.19, S * 0.19))
save(fg, "icon_fg.png")
save(background(S).convert("RGB"), "icon_bg.png")

# Windows .ico source is the full icon; 256px preview for the README.
save(full, "icon_256.png", 256)
print("wrote", sorted(p.name for p in OUT.iterdir()))
