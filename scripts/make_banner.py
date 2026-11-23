#!/usr/bin/env python3
"""Draws docs/images/banner.png: the app icon's night cove (moon, hills, reflection, the notch) with the Cove wordmark in
Zapfino. Needs Pillow and macOS's own fonts.   python3 scripts/make_banner.py"""
import math, random
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 2400, 640                      # drawn at 2x, saved at half size
horizon = int(H * 0.74)
SUP = "/System/Library/Fonts/Supplemental/"

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))
def grad(stops, t):
    t = max(0, min(1, t))
    for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
        if t <= t1: return lerp(c0, c1, (t - t0) / (t1 - t0))
    return stops[-1][1]

sky = [(0, (34, 30, 72)), (0.5, (88, 54, 142)), (0.85, (152, 90, 172)), (1, (224, 128, 172))]
water = [(0, (60, 66, 170)), (0.4, (36, 40, 124)), (1, (8, 10, 40))]
img = Image.new("RGB", (W, H)); d = ImageDraw.Draw(img)
for y in range(H):
    d.line((0, y, W, y), fill=grad(sky, y / horizon) if y < horizon else grad(water, (y - horizon) / (H - horizon)))

mx, my, mr = int(W * 0.66), int(H * 0.36), 78          # the moon sits right of the title
glow = Image.new("RGBA", (W, H), (0, 0, 0, 0)); g = ImageDraw.Draw(glow)
for r, a in [(380, 22), (270, 30), (180, 44), (120, 60)]:
    g.ellipse((mx - r, my - r, mx + r, my + r), fill=(190, 170, 255, a))
img.paste(glow.filter(ImageFilter.GaussianBlur(40)), (0, 0), glow.filter(ImageFilter.GaussianBlur(40)))
d = ImageDraw.Draw(img, "RGBA")

random.seed(11)
for _ in range(110):
    x = random.randint(0, W); y = random.randint(0, int(horizon * 0.85)); r = random.choice([2, 2, 3, 4])
    if abs(x - mx) < 140 and abs(y - my) < 140: continue
    d.ellipse((x - r, y - r, x + r, y + r), fill=(255, 255, 255, random.randint(110, 230)))

moon = Image.new("RGBA", (mr * 2, mr * 2)); md = ImageDraw.Draw(moon)
for yy in range(mr * 2): md.line((0, yy, mr * 2, yy), fill=lerp((252, 252, 255), (214, 220, 255), yy / (mr * 2)) + (255,))
mask = Image.new("L", (mr * 2, mr * 2), 0); ImageDraw.Draw(mask).ellipse((0, 0, mr * 2 - 1, mr * 2 - 1), fill=255)
img.paste(moon, (mx - mr, my - mr), mask); d = ImageDraw.Draw(img, "RGBA")

def ridge(side, top, reach, shift):
    pts = []
    for i in range(241):
        x = i / 240 * reach; t = x / reach
        h = top * (0.5 * (1 + math.cos(math.pi * t))) ** 1.35 * (1 + 0.10 * math.sin(t * 6.0 + shift))
        pts.append((x if side == "l" else W - x, horizon - h))
    return pts
for side, top, reach, shift in (("l", 70, W * 0.28, 0.6), ("r", 118, W * 0.34, 1.7)):
    pts = ridge(side, top, reach, shift)
    d.polygon([(0 if side == "l" else W, horizon + 1)] + pts + [(pts[-1][0], horizon + 1)], fill=(26, 20, 84, 255))

y = horizon + 22
for i, w in enumerate([170, 112, 140, 90, 120, 76, 100, 64, 86, 56]):
    d.rounded_rectangle((mx - w // 2, y, mx + w // 2, y + 12), radius=6, fill=(196, 202, 255, int(190 * (1 - i / 10)))); y += 26

for side, top, reach in (("l", 250, W * 0.18), ("r", 230, W * 0.17)):
    pts = []
    for i in range(161):
        x = i / 160 * reach; t = x / reach
        pts.append((x if side == "l" else W - x, H - top * (1 - t) ** 1.8))
    d.polygon([(0 if side == "l" else W, H)] + pts + [(pts[-1][0], H)], fill=(7, 6, 28, 255))

nw, nh = 270, 74                                       # the notch, centred like the real one
d.rounded_rectangle((W // 2 - nw // 2, -40, W // 2 + nw // 2, nh), radius=30, fill=(2, 2, 10, 255), outline=(125, 125, 155, 150), width=2)

def font(path, size, index=0):
    try: return ImageFont.truetype(path, size, index=index)
    except Exception: return ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", size)
tag_font = font(SUP + "Zapfino.ttf", 40)
title_font = font(SUP + "Zapfino.ttf", 170)
x0, ink_top = 140, 78
box = ImageDraw.Draw(Image.new("L", (10, 10))).textbbox((0, 0), "Cove", font=title_font)
ox, oy = x0 - box[0], ink_top - box[1]                # place the lettering by its ink, not by the font's tall metrics
ink_h = box[3] - box[1]
shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0)); ImageDraw.Draw(shadow).text((ox, oy), "Cove", font=title_font, fill=(10, 4, 40, 170))
blur = shadow.filter(ImageFilter.GaussianBlur(14)); img.paste(blur, (0, 8), blur)
text = Image.new("L", (W, H), 0); ImageDraw.Draw(text).text((ox, oy), "Cove", font=title_font, fill=255)
tint = Image.new("RGB", (W, H)); td = ImageDraw.Draw(tint)
for yy in range(H): td.line((0, yy, W, yy), fill=lerp((255, 255, 255), (214, 206, 255), max(0, min(1, (yy - ink_top) / max(ink_h, 1)))))
img.paste(tint, (0, 0), text)
d = ImageDraw.Draw(img, "RGBA")
tag = "One notch for the whole Mac"
tb = d.textbbox((0, 0), tag, font=tag_font)
d.text((x0 + 14 - tb[0], ink_top + ink_h + 22 - tb[1]), tag, font=tag_font, fill=(226, 230, 255, 240))
img.resize((W // 2, H // 2), Image.LANCZOS).save("docs/images/banner.png", optimize=True)
print("docs/images/banner.png")
