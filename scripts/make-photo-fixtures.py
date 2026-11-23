#!/usr/bin/env python3
"""Generates small real image files for testing the photo library (needs Pillow; HEIC through macOS sips).

    scripts/make-photo-fixtures.py <dir> [many_dir] [count]

<dir> gets a handful of files that exercise the importer: dated and undated photos, a rotated one, every supported format,
formats that are skipped, a broken file, a hidden folder, a non-ASCII name. `many_dir` gets `count` (default 3000) small
JPEGs with random EXIF dates, for scale checks."""
import os, random, subprocess, sys
from PIL import Image, ImageDraw

def exif_bytes(date=None, orientation=None):
    ex = Image.Exif()
    if orientation: ex[0x0112] = orientation
    if date:
        ex[0x8769] = {0x9003: date, 0x9004: date}   # DateTimeOriginal, DateTimeDigitized
    return ex

def make(path, size, color, text="", date=None, orientation=None, fmt=None, **kw):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img = Image.new("RGB", size, color)
    d = ImageDraw.Draw(img); d.rectangle([8, 8, size[0] - 9, size[1] - 9], outline=(255, 255, 255), width=4)
    d.text((20, 20), text or os.path.basename(path), fill=(255, 255, 255))
    save_kw = dict(kw)
    if fmt in (None, "JPEG"): save_kw["exif"] = exif_bytes(date, orientation)
    img.save(path, fmt, **save_kw)

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
make(f"{out}/trip/IMG_0001.jpg", (800, 600), (200, 60, 60), date="2019:05:01 10:00:00")
make(f"{out}/trip/IMG_0002.jpg", (800, 600), (60, 160, 60), date="2019:05:02 11:30:00", orientation=6)   # shown 600 x 800
make(f"{out}/trip/IMG_0003.jpg", (640, 480), (60, 60, 200), date="2020:01:15 08:15:30")
make(f"{out}/family/photo.png", (500, 500), (150, 150, 40), fmt="PNG")
frames = [Image.new("RGB", (200, 200), c) for c in [(255, 0, 0), (0, 255, 0), (0, 0, 255)]]
os.makedirs(f"{out}/family", exist_ok=True)
frames[0].save(f"{out}/family/anim.gif", save_all=True, append_images=frames[1:], duration=200, loop=0)
make(f"{out}/family/scan.tiff", (300, 400), (90, 90, 90), fmt="TIFF")
make(f"{out}/family/shot.bmp", (320, 240), (10, 120, 160), fmt="BMP")
try:
    make(f"{out}/family/pic.webp", (400, 300), (120, 40, 160), fmt="WEBP")
except Exception as e:
    print("no webp:", e)
make(f"{out}/family/for_heic.jpg", (640, 480), (30, 30, 30), date="2021:07:04 16:20:00")
subprocess.run(["sips", "-s", "format", "heic", f"{out}/family/for_heic.jpg", "--out", f"{out}/family/photo.heic"], capture_output=True)
os.remove(f"{out}/family/for_heic.jpg")
make(f"{out}/unicode/旅行 照片.jpg", (300, 200), (200, 120, 20), date="2022:12:25 09:00:00")
make(f"{out}/disguised.jpg", (200, 200), (1, 2, 3), fmt="PNG")                   # PNG data under a .jpg name
make(f"{out}/.hidden/secret.jpg", (100, 100), (9, 9, 9), date="2010:01:01 00:00:00")
make(f"{out}/zero_date.jpg", (100, 100), (50, 50, 50), date="0000:00:00 00:00:00")
for name in ("raw/IMG_9999.cr2", "design.psd", "notes.txt"):
    os.makedirs(os.path.dirname(f"{out}/{name}") or out, exist_ok=True)
    open(f"{out}/{name}", "wb").write(b"not really an image")
open(f"{out}/broken.jpg", "w").write("this is not a jpeg")
print("fixtures in", out)

if len(sys.argv) > 2:
    many, count = sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 3000
    random.seed(7)
    for i in range(count):
        year = random.randint(2015, 2024)
        date = f"{year}:{random.randint(1,12):02d}:{random.randint(1,28):02d} {random.randint(0,23):02d}:{random.randint(0,59):02d}:{random.randint(0,59):02d}"
        make(f"{many}/{year}/IMG_{i:05d}.jpg", (160, 120), (random.randint(0, 255), random.randint(0, 255), random.randint(0, 255)), text=str(i), date=date)
    print(count, "files in", many)
