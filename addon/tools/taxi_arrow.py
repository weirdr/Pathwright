#!/usr/bin/env python3
"""The flight map's arrow (Taxi.lua): addon/Pathwright_Guide/Media/TaxiArrow.tga.

A green arrow pointing down, without a border, with a soft glow of its own green that is gone
within GLOW px of its edge at the size it has on screen. The texture holds the arrow with room
for the glow around it: Taxi.lua shows it SIZE px wide so that the arrow itself is ON_SCREEN px,
and lowers it by the room under its tip (its ROOM).

    python3 addon/tools/taxi_arrow.py [--png preview.png] [--check]
"""

import argparse
import math
import pathlib
import struct
import sys
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "addon" / "Pathwright_Guide" / "Media" / "TaxiArrow.tga"
# The texture's side (a power of two, as the game asks).
PIXELS = 128
# The arrow's silhouette, in units: it fills a box of BOX units.
SHAPE = [(20, 2), (44, 2), (44, 27), (61, 27), (32, 63.5), (3, 27), (20, 27)]
BOX = 64.0
# On screen the arrow is ON_SCREEN px; its glow stops GLOW px from its edge.
ON_SCREEN, GLOW = 30.0, 5.0
REACH = BOX * GLOW / ON_SCREEN  # the glow's reach, in units
MARGIN = math.ceil(REACH)  # the room for it around the arrow
UNITS = BOX + 2 * MARGIN  # the texture's side, in units
# The glow at the arrow's edge (of 1), and how fast it fades from there.
STRENGTH, POWER = 0.5, 2.5
TOP, BOTTOM = (0x76, 0xF8, 0x65), (0x42, 0xCF, 0x40)
GLOW_COLOR = (0x66, 0xEB, 0x5C)


def inside(x, y):
    hit = False
    for i, (x1, y1) in enumerate(SHAPE):
        x2, y2 = SHAPE[(i + 1) % len(SHAPE)]
        if (y1 > y) != (y2 > y) and x < x1 + (y - y1) * (x2 - x1) / (y2 - y1):
            hit = not hit
    return hit


def distance(x, y):
    best = math.inf
    for i, (x1, y1) in enumerate(SHAPE):
        x2, y2 = SHAPE[(i + 1) % len(SHAPE)]
        dx, dy = x2 - x1, y2 - y1
        t = max(0.0, min(1.0, ((x - x1) * dx + (y - y1) * dy) / (dx * dx + dy * dy)))
        best = min(best, math.hypot(x - x1 - t * dx, y - y1 - t * dy))
    return best


def fill(x, y):
    """The arrow's green: lighter at the top, a soft highlight down its left of centre."""
    t = max(0.0, min(1.0, (y - 4) / 56.0))
    base = [TOP[i] + (BOTTOM[i] - TOP[i]) * t for i in range(3)]
    shine = max(0.0, 1 - abs(x - 28) / 8.0) * (0.35 - 0.25 * t)
    return [c + (255 - c) * shine for c in base]


def render(size):
    """Rows of (red, green, blue, alpha), top first. Where nothing shows the colour is still the
    glow's: the game blends neighbouring pixels, and black there would darken the edge."""
    scale = size / UNITS
    rows = []
    for py in range(size):
        row = []
        for px in range(size):
            x, y = (px + 0.5) / scale - MARGIN, (py + 0.5) / scale - MARGIN
            d = distance(x, y)
            signed = -d if inside(x, y) else d
            # The arrow's own edge, one pixel soft; the glow outside it.
            arrow = max(0.0, min(1.0, 0.5 - signed * scale))
            glow = STRENGTH * (1 - signed / REACH) ** POWER if 0 < signed < REACH else (STRENGTH if signed <= 0 else 0.0)
            alpha = arrow + glow * (1 - arrow)
            if alpha <= 0:
                row.append((*GLOW_COLOR, 0))
                continue
            f = fill(x, y)
            rgb = [(f[i] * arrow + GLOW_COLOR[i] * glow * (1 - arrow)) / alpha for i in range(3)]
            row.append((*(round(max(0, min(255, c))) for c in rgb), round(alpha * 255)))
        rows.append(row)
    return rows


def tga(rows):
    """An uncompressed 32-bit Targa, the top row first."""
    size = len(rows)
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, size, size, 32, 0x28)
    return header + b"".join(bytes((b, g, r, a)) for row in rows for r, g, b, a in row)


def png(rows):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    size = len(rows)
    raw = b"".join(b"\0" + b"".join(bytes(p) for p in row) for row in rows)
    head = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", head) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--png", help="also write a PNG of it there, to look at")
    ap.add_argument("--check", action="store_true", help="fail when the texture is not up to date")
    args = ap.parse_args()
    rows = render(PIXELS)
    data = tga(rows)
    if args.check:
        if not OUT.exists() or OUT.read_bytes() != data:
            sys.exit(f"{OUT.relative_to(ROOT)} is not up to date: run addon/tools/taxi_arrow.py")
        return
    OUT.write_bytes(data)
    if args.png:
        pathlib.Path(args.png).write_bytes(png(rows))
    side = ON_SCREEN * UNITS / BOX
    print(f"{OUT.relative_to(ROOT)}: {PIXELS} px; shown {side:.1f} px wide, {side * MARGIN / UNITS:.1f} px of room under the tip")


if __name__ == "__main__":
    main()
