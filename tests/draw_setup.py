#!/usr/bin/env python3
"""Render the ZugLoot Setup tab (MainWindow.RenderSetup panels) out of game.

Reads the panel/section layout from the addon's own MainWindow.lua so the
mock can never drift: section titles + order, heading/row/button geometry,
two-column placement (Looting left, Rolling + Automation right, Danger
zone full-width below).
Usage: python3 tests/draw_setup.py [--out preview/setup.png]
"""
import math
import os
import re
import sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    sys.exit("needs Pillow: pip install pillow")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAIN = os.path.join(ROOT, "MainWindow.lua")
SRC = open(MAIN).read()

# ---- layout constants parsed from RenderSetup ---------------------------
BODY_W = int(re.search(r"local BODY_WIDTH\s*=\s*(\d+)", SRC).group(1))
GOLD = tuple(float(x) for x in
             re.search(r"gold\s*=\s*\{\s*([0-9.]+),\s*([0-9.]+),\s*([0-9.]+)",
                       SRC).groups())
TINT_A = float(re.search(r"SETUP_PANEL_TINT[^}]*?,\s*([0-9.]+)\s*\}", SRC).group(1))
EDGE_A = float(re.search(r"SETUP_PANEL_EDGE[^}]*?,\s*([0-9.]+)\s*\}", SRC).group(1))
R = 8  # corner radius in SetupPanel

BH, SMALL_H = 24, 20
PAD_TOP, PAD_BOT, GAP = 24, 8, 10
BW = 150

TITLES = [m.group(1).strip().split("—")[0].strip()
          for m in re.finditer(r"-- Section \d+: ([^\n]+)", SRC)]

# Column metrics mirror the Lua centering (computed in the GRID_W
# block below from the same BODY_WIDTH/GAP the addon uses).

BUTTONS = {
    "Rolling": ["Auto-roll: ON", "Roll window: ML"],
    "Looting": ["Loot frame: ZUG", "ML on boss: OFF", "Back to group: OFF",
                "Threshold: Epic (4)", "Announce: Rare (3)"],
    "Danger zone": ["Reset all settings"],
}
AUTO_CATS = ["ZG coins/bijous", "MC mats", "AQ scarabs/idols",
             "Corrupted Sand", "Dream shards", "Naxx scraps",
             "Necrotic Runes"]
LOOTING_INFO = ["Drops logged: 0  (/zl log)"]

GRID_W = BODY_W - 8
# Members-tab remainder split + the window-axis chrome shift
# (mirrors RenderSetup: body sits +14 in winW, pair shifts right by
# half the L/R chrome difference so it lands on the window axis).
COL_W = (GRID_W - GAP) // 2
WIN_W = BODY_W + 64
BODY_LEFT = 14
CHROME_SHIFT = max(0, ((WIN_W - (BODY_LEFT + BODY_W)) - BODY_LEFT) // 2)
MARGIN_X = 4 + (GRID_W - (COL_W * 2 + GAP)) // 2 + CHROME_SHIFT
LEFT_X, RIGHT_X = MARGIN_X, MARGIN_X + COL_W + GAP
# now that COL_W is final, derive the dependent button/grid metrics.
# Mirrors the Lua builders: duoW pairs everywhere, full-width singles.
DUO_W = (COL_W - 16 - 8) // 2
N_CATS = 6  # AutoRoll.CATEGORIES count
_auto_rows = math.ceil(N_CATS / 2)
CONTENT = {
    "Rolling": BH + 8 + 45,  # duo pair + timer cell (readout/track/captions)
    "Looting": BH + 8 + BH + 8 + BH + 8 + 21,  # 3 duo rows + drop-count line
    "Automation": (_auto_rows * SMALL_H + (_auto_rows - 1) * 4
                     + 8 + SMALL_H),
    "Danger zone": BH,
}
panels = {}  # title -> (x, top, w, h)
ly = ry = 52
for t in ["Rolling", "Looting", "Automation"]:
    h = PAD_TOP + CONTENT[t] + PAD_BOT
    if t == "Looting":
        panels[t] = (LEFT_X, ly, COL_W, h)
        ly += h + GAP
    else:
        panels[t] = (RIGHT_X, ry, COL_W, h)
        ry += h + GAP
h = PAD_TOP + CONTENT["Danger zone"] + PAD_BOT
panels["Danger zone"] = (LEFT_X, ly, COL_W, h)
ly += h + GAP
ROW_H = max(ly, ry) - GAP + 52

# ---- canvas ---------------------------------------------------------------
W = 900
BG = (14, 15, 18)
INK = (232, 230, 225)
MUTE = (140, 143, 153)
HDR_H = 108
TOP = HDR_H + 118
TOTAL_H = TOP + ROW_H + 30

img = Image.new("RGB", (W, TOTAL_H), BG)
d = ImageDraw.Draw(img, "RGBA")
G = (int(GOLD[0] * 255), int(GOLD[1] * 255), int(GOLD[2] * 255))


def font(sz, bold=False):
    cands = [
        "/usr/share/fonts/liberation-sans-fonts/LiberationSans-%s.ttf"
        % ("Bold" if bold else "Regular"),
        "/usr/share/fonts/dejavu/DejaVuSans%s.ttf" % ("-Bold" if bold else ".ttf"),
    ]
    for c in cands:
        if os.path.exists(c):
            return ImageFont.truetype(c, sz)
    return ImageFont.load_default()


F_BTN = font(13)
F_SMALL = font(12)
F_HEAD = font(15, True)
F_BRAND = font(26, True)

d.rectangle([0, 0, W, 2], fill=G)
d.text((16, 14), "ZUGLOOT", font=F_BRAND, fill=G)
# No tab header in-game anymore: the SETUP tab speaks for itself.

tabs = ["SHEET", "RAIDS", "PYSANKA", "MEMBERS", "SETUP"]
tx = 560
for t in tabs:
    w = 44 if t != "PYSANKA" else 70
    col = G if t == "SETUP" else MUTE
    d.text((tx, HDR_H - 26), t, font=font(12, True), fill=col)
    if t == "SETUP":
        d.rectangle([tx, HDR_H - 8, tx + 44, HDR_H - 6], fill=G)
    tx += w + 18


def rounded_panel(x0, y0, x1, y1, tint_a=TINT_A, edge_a=EDGE_A):
    tint = (G[0], G[1], G[2], int(255 * tint_a))
    edge = (G[0], G[1], G[2], int(255 * edge_a))
    d.rectangle([x0, y0 + R, x1, y1 - R], fill=tint)
    d.rectangle([x0 + R, y0, x1 - R, y0 + R], fill=tint)
    d.rectangle([x0 + R, y1 - R, x1 - R, y1], fill=tint)
    d.line([x0 + R, y0, x1 - R, y0], fill=edge)
    d.line([x0 + R, y1, x1 - R, y1], fill=edge)
    d.line([x0, y0 + R, x0, y1 - R], fill=edge)
    d.line([x1, y0 + R, x1, y1 - R], fill=edge)
    for cx, cy in [(x0 + 3, y0 + 3), (x1 - 3, y0 + 3),
                   (x0 + 3, y1 - 3), (x1 - 3, y1 - 3)]:
        d.ellipse([cx - 2, cy - 2, cx + 1, cy + 1], fill=edge)


def slider(x, y, w, cur=10, lo=1, hi=30):
    d.line([x, y + 8, x + w, y + 8], fill=(120, 122, 130))
    fx = x + (cur - lo) / max(1, hi - lo) * w
    d.ellipse([fx - 5, y + 3, fx + 5, y + 13], fill=G)
    d.text((x + 2, y + 16), "%d" % lo, font=F_SMALL, fill=MUTE)
    tw = d.textlength("%d" % hi, font=F_SMALL)
    d.text((x + w - tw - 2, y + 16), "%d" % hi, font=F_SMALL, fill=MUTE)


def button(x, y, w, h, label):
    d.rectangle([x, y, x + w, y + h], outline=(120, 122, 130), width=1)
    d.rectangle([x + 1, y + 1, x + w - 1, y + h - 1], fill=(40, 42, 52))
    tw = d.textlength(label, font=F_BTN)
    d.text((x + (w - tw) / 2, y + (h - 13) / 2 - 1), label, font=F_BTN, fill=INK)


for title in TITLES:
    x, top, w, h = panels[title]
    y0 = TOP + top
    rounded_panel(x, y0, x + w, y0 + h)
    d.text((x + 8, y0 + 6), title, font=F_HEAD, fill=G)
    by, bx = y0 + PAD_TOP, x + 8
    if title in ("Rolling", "Looting"):
        # mirrors the Lua duoButton pairs: two-across, PAD_SIDE margins.
        bl = BUTTONS[title]
        for r in range(0, len(bl), 2):
            button(bx, by + (r // 2) * (BH + 8), DUO_W, BH, bl[r])
            if r + 1 < len(bl):
                button(bx + DUO_W + 8, by + (r // 2) * (BH + 8),
                       DUO_W, BH, bl[r + 1])
        by += ((len(bl) + 1) // 2) * (BH + 8) - 8
        if title == "Rolling":
            # timer cell: readout + custom track + captions in ONE
            # duo cell under the duo pair (no text box: readout
            # shows the value).
            by += 8
            d.text((bx + DUO_W - 20, by), "10s", font=F_SMALL, fill=MUTE)
            slider(bx, by + 10, DUO_W, 10)
            by += 45
        if title == "Looting":
            by += 8
            for line in LOOTING_INFO:
                d.text((bx, by + 2), line, font=F_SMALL, fill=MUTE)
                by += 15
    elif title == "Automation":
        for i, c in enumerate(AUTO_CATS):
            col, rr = i % 2, i // 2
            button(bx + col * (DUO_W + 8), by + rr * (SMALL_H + 4),
                   DUO_W, SMALL_H, "%s: OFF" % c)
        by += 3 * (SMALL_H + 4) - 4 + 8
        button(bx, by, COL_W - 16, SMALL_H, "Auto-loot below: OFF")
    elif title == "Danger zone":
        button(bx, by, COL_W - 16, BH, BUTTONS[title][0])

out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv \
    else os.path.join(ROOT, "preview", "setup.png")
os.makedirs(os.path.dirname(out), exist_ok=True)
img.save(out)
print("wrote", out, img.size)
