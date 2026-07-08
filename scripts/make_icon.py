#!/usr/bin/env python3
"""Generate the Tonearm app icon: periodic-table tile for Pt (Platinum).
Brass (#E3A44B) on a dark radial-gradient field, matching the design system.
"""
from PIL import Image, ImageDraw, ImageFont
import math

SIZE = 1024
BG_TOP = (18, 20, 26)
BG_BOT = (10, 11, 13)
BRASS = (227, 164, 75)
BRASS_DEEP = (145, 100, 42)
INK = (242, 244, 246)
INK3 = (128, 133, 140)

FONT_BOLD = "/System/Library/Fonts/Helvetica.ttc"
FONT_REG = "/System/Library/Fonts/Helvetica.ttc"

# On macOS the .ttc needs a face index — better to pick an individual path.
import glob
def find_font(name):
    for p in glob.glob("/System/Library/Fonts/*" + name + "*"):
        if not p.endswith(".ttc"):
            return p
    return FONT_REG

def ttf(size, bold=False):
    p = find_font("Helvetica") if not bold else find_font("Helvetica")
    try:
        return ImageFont.truetype(p, size)
    except:
        return ImageFont.load_default()

img = Image.new("RGB", (SIZE, SIZE), BG_BOT)
draw = ImageDraw.Draw(img)

# Vertical gradient.
for y in range(SIZE):
    t = y / SIZE
    r = int(BG_TOP[0] * (1 - t) + BG_BOT[0] * t)
    g = int(BG_TOP[1] * (1 - t) + BG_BOT[1] * t)
    b = int(BG_TOP[2] * (1 - t) + BG_BOT[2] * t)
    draw.line([(0, y), (SIZE, y)], fill=(r, g, b))

# Radial brass glow.
glow = Image.new("L", (SIZE, SIZE), 0)
gd = ImageDraw.Draw(glow)
cx, cy = int(SIZE * 0.28), int(SIZE * 0.08)
maxr = int(SIZE * 0.80)
for rr in range(maxr, 0, -3):
    a = int(55 * (1 - rr / maxr) ** 2.2)
    gd.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], fill=a)
glow_col = Image.new("RGB", (SIZE, SIZE), BRASS)
img = Image.composite(glow_col, img, glow)
draw = ImageDraw.Draw(img)

# Rounded tile border.
margin = int(SIZE * 0.115)
radius = int(SIZE * 0.11)
draw.rounded_rectangle([margin, margin, SIZE - margin, SIZE - margin], radius=radius, outline=BRASS_DEEP, width=10)
# Inner brass hairline
draw.rounded_rectangle([margin + 16, margin + 16, SIZE - margin - 16, SIZE - margin - 16], radius=radius - 8, outline=BRASS, width=4)

# Atomic number "73" — top-left.
try:
    f_num = ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", 130, index=1)
except:
    f_num = ttf("", size=130, bold=True)
draw.text((margin + 65, margin + 48), "78", font=f_num, fill=BRASS)

# "Ta" symbol — large, centered.
sym = "Pt"
try:
    f_sym = ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", 420, index=1)
except:
    f_sym = ttf("", size=420, bold=True)
bbox = draw.textbbox((0, 0), sym, font=f_sym)
sw = bbox[2] - bbox[0]
sh = bbox[3] - bbox[1]
sx = (SIZE - sw) // 2 - bbox[0]
sy = (SIZE - sh) // 2 - bbox[1] - 35
draw.text((sx, sy), sym, font=f_sym, fill=BRASS)

# "Platterhead" — below symbol.
try:
    f_name = ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", 78, index=0)
except:
    f_name = ttf("", size=78, bold=False)
name = "Platterhead"
nb = draw.textbbox((0, 0), name, font=f_name)
nw = nb[2] - nb[0]
draw.text(((SIZE - nw) // 2 - nb[0], SIZE - margin - 200), name, font=f_name, fill=INK)

# "180.95" — atomic weight at bottom.
try:
    f_wt = ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", 60, index=0)
except:
    f_wt = ttf("", size=60, bold=False)
wt = "195.08"
wb_d = draw.textbbox((0, 0), wt, font=f_wt)
ww = wb_d[2] - wb_d[0]
draw.text(((SIZE - ww) // 2 - wb_d[0], SIZE - margin - 130), wt, font=f_wt, fill=INK3)

import sys
out = sys.argv[1] if len(sys.argv) > 1 else "AppIcon-1024.png"
img.save(out, "PNG")
print("wrote", out)
