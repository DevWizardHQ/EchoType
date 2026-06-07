#!/usr/bin/env python3
"""Generates the DMG installer background (1x + 2x + combined .tiff).

Layout matches the create-dmg flags in .github/workflows/release.yml:
window 660x400, app icon centered at (165, 200), Applications link at (495, 200).
"""
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import os, subprocess

W, H = 660, 400          # logical window size
S = 2                    # render at 2x, downscale for 1x

def font(size, bold=False):
    candidates = [
        ("/System/Library/Fonts/SFNS.ttf", 0),
        ("/System/Library/Fonts/HelveticaNeue.ttc", 1 if bold else 0),
        ("/System/Library/Fonts/Helvetica.ttc", 1 if bold else 0),
    ]
    for path, index in candidates:
        try:
            return ImageFont.truetype(path, size, index=index)
        except Exception:
            continue
    return ImageFont.load_default()

img = Image.new("RGB", (W * S, H * S))
draw = ImageDraw.Draw(img, "RGBA")

# Vertical gradient: deep navy -> indigo -> violet (matches the app icon).
top, mid, bottom = (16, 14, 36), (43, 35, 96), (76, 50, 140)
for y in range(H * S):
    t = y / (H * S - 1)
    if t < 0.55:
        u = t / 0.55
        c = tuple(round(top[i] + (mid[i] - top[i]) * u) for i in range(3))
    else:
        u = (t - 0.55) / 0.45
        c = tuple(round(mid[i] + (bottom[i] - mid[i]) * u) for i in range(3))
    draw.line([(0, y), (W * S, y)], fill=c)

# Soft radial glow behind the centerline where the icons sit.
glow = Image.new("RGBA", (W * S, H * S), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
cx, cy = W * S // 2, 205 * S
gd.ellipse([cx - 230 * S, cy - 120 * S, cx + 230 * S, cy + 120 * S],
           fill=(120, 110, 255, 38))
glow = glow.filter(ImageFilter.GaussianBlur(70 * S))
img = Image.alpha_composite(img.convert("RGBA"), glow)
draw = ImageDraw.Draw(img, "RGBA")

# Title + tagline.
title_f = font(34 * S, bold=True)
sub_f = font(15 * S)
hint_f = font(14 * S)

def center_text(y, text, f, fill):
    w = draw.textlength(text, font=f)
    draw.text(((W * S - w) / 2, y * S), text, font=f, fill=fill)

center_text(36, "EchoType", title_f, (255, 255, 255, 240))
center_text(86, "Hold a key. Speak. It types.", sub_f, (255, 255, 255, 140))

# Dashed arrow between the two icon slots (icons are 128 px at y=200).
y = 205 * S
x0, x1 = 250 * S, 408 * S
dash, gap = 14 * S, 9 * S
x = x0
while x < x1 - 26 * S:
    draw.line([(x, y), (min(x + dash, x1 - 26 * S), y)],
              fill=(255, 255, 255, 165), width=5 * S)
    x += dash + gap
# Arrow head.
ah = 13 * S
draw.polygon([(x1, y), (x1 - 2 * ah, y - ah), (x1 - 2 * ah, y + ah)],
             fill=(255, 255, 255, 195))

# Install hint at the bottom.
center_text(338, "Drag EchoType into Applications to install", hint_f, (255, 255, 255, 150))
center_text(362, "First launch: right-click the app and choose Open", hint_f, (255, 255, 255, 90))

out_dir = os.path.dirname(os.path.abspath(__file__))
res = os.path.join(os.path.dirname(out_dir), "Resources")
img2x = img.convert("RGB")
img1x = img2x.resize((W, H), Image.LANCZOS)
p1 = os.path.join(res, "dmg-background.png")
p2 = os.path.join(res, "dmg-background@2x.png")
img1x.save(p1)
img2x.save(p2)

# Combined retina tiff for create-dmg.
tiff = os.path.join(res, "dmg-background.tiff")
subprocess.run(["tiffutil", "-cathidpicheck", p1, p2, "-out", tiff], check=True)
print("wrote", p1, p2, tiff)
