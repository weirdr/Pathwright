#!/usr/bin/env python3
"""Draw the toolstrip's icons (Pathwright_Guide/Media/Kill.tga, Talk.tga, Trash.tga) and the
nameplates' money bag (Loot.tga).

Each is a 64x64 image: a flat coloured symbol (a red sword, a green speech bubble, a grey trash can)
on a clear background (the toolstrip has its own). Drawn here from simple shapes, supersampled
for smooth edges, and written as uncompressed 32-bit TGA (top-left origin) like the addon's other
textures.

From the repository root: python3 addon/tools/toolstrip_icons.py
"""

import math
import os
import struct

SIZE = 64
SAMPLES = 4
OUT = os.path.join(os.path.dirname(__file__), "..", "Pathwright_Guide", "Media")


def rounded(x0, y0, x1, y1, r):
    """Inside a rounded rectangle."""

    def inside(x, y):
        if not (x0 <= x <= x1 and y0 <= y <= y1):
            return False
        cx = min(max(x, x0 + r), x1 - r)
        cy = min(max(y, y0 + r), y1 - r)
        return (x - cx) ** 2 + (y - cy) ** 2 <= r * r

    return inside


def ellipse(cx, cy, rx, ry):
    return lambda x, y: ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 <= 1


def polygon(points):
    """Inside a convex or concave polygon (even-odd rule)."""

    def inside(x, y):
        hit = False
        j = len(points) - 1
        for i, (xi, yi) in enumerate(points):
            xj, yj = points[j]
            if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
                hit = not hit
            j = i
        return hit

    return inside


def union(*shapes):
    return lambda x, y: any(s(x, y) for s in shapes)


def grow(points, d):
    """A polygon pushed out by `d` from its centre (for outlines)."""
    cx = sum(p[0] for p in points) / len(points)
    cy = sum(p[1] for p in points) / len(points)
    out = []
    for x, y in points:
        dx, dy = x - cx, y - cy
        n = math.hypot(dx, dy) or 1
        out.append((x + dx / n * d, y + dy / n * d))
    return out


def lerp(a, b, t):
    t = max(0.0, min(1.0, t))
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def axis_shape(ox, oy, angle, parts):
    """Shapes along an axis through (ox, oy): parts are (t0, t1, halfwidth(t)) in axis units."""
    ca, sa = math.cos(angle), math.sin(angle)

    def inside(x, y):
        dx, dy = x - ox, y - oy
        t = dx * ca + dy * sa
        v = -dx * sa + dy * ca
        for t0, t1, half in parts:
            if t0 <= t <= t1 and abs(v) <= half(t):
                return True
        return False

    return inside


def sword_layers():
    ox, oy, angle = 32, 32, math.radians(45)  # the blade points up-left, the pommel down-right

    def parts(pad):
        return [
            (-24 - pad, -15, lambda t: max(0.0, 5.2 + pad - (-15 - t) * 5.2 / 9)),  # the point
            (-15, 5, lambda t: 5.2 + pad),  # the blade
            (5 - pad, 10 + pad, lambda t: 12.5 + pad),  # the cross-guard
            (10, 17, lambda t: 3.2 + pad),  # the grip
            (17 - pad, 22 + pad, lambda t: 4.6 + pad),  # the pommel
        ]

    ca, sa = math.cos(angle), math.sin(angle)

    def light(x, y):
        # The blade's upper edge lighter.
        v = -(x - ox) * sa + (y - oy) * ca
        t = (x - ox) * ca + (y - oy) * sa
        return v < 0 and t < 5

    return [
        (axis_shape(ox, oy, angle, parts(1.6)), lambda x, y: (70, 8, 8)),
        (axis_shape(ox, oy, angle, parts(0)), lambda x, y: (214, 36, 36)),
        (lambda x, y: axis_shape(ox, oy, angle, parts(0))(x, y) and light(x, y), lambda x, y: (246, 92, 84)),
    ]


def bubble_layers():
    tail = [(19, 36), (30, 41), (12, 52)]
    body = lambda pad: union(ellipse(33, 28, 20 + pad, 15 + pad), polygon(grow(tail, pad)))
    return [
        (body(1.8), lambda x, y: (12, 64, 12)),
        (body(0), lambda x, y: lerp((132, 238, 96), (34, 150, 30), (y - 12) / 40)),
        (ellipse(27, 21, 9, 4.5), lambda x, y: (178, 250, 150)),  # the shine
    ]


def trash_layers():
    def body(pad):
        return polygon([(17 - pad, 23 - pad), (47 + pad, 23 - pad), (43 + pad, 55 + pad), (21 - pad, 55 + pad)])

    def lid(pad):
        return rounded(13 - pad, 16 - pad, 51 + pad, 21 + pad, 1.5)

    def handle(pad):
        outer = rounded(25 - pad, 9 - pad, 39 + pad, 18, 3)
        inner = rounded(28 + pad, 12 + pad, 36 - pad, 18, 1)
        return lambda x, y: outer(x, y) and not inner(x, y)

    grey = lambda x, y: lerp((206, 206, 210), (124, 124, 130), (y - 9) / 48)
    return [
        (union(body(1.6), lid(1.6), handle(1.6)), lambda x, y: (40, 40, 44)),
        (handle(0), grey),
        (lid(0), grey),
        (body(0), grey),
        (rounded(20, 23, 44, 26, 1), lambda x, y: (96, 96, 102)),  # the shadow under the lid
    ]


def render(layers):
    px = bytearray()
    for py in range(SIZE):
        for pxl in range(SIZE):
            r = g = b = a = 0.0
            for sy in range(SAMPLES):
                for sx in range(SAMPLES):
                    x = pxl + (sx + 0.5) / SAMPLES
                    y = py + (sy + 0.5) / SAMPLES
                    color = None
                    for inside, paint in layers:
                        if inside(x, y):
                            color = paint(x, y)
                    if color:
                        r, g, b, a = r + color[0], g + color[1], b + color[2], a + 1
            if a:
                px += bytes((int(b / a), int(g / a), int(r / a), int(255 * a / SAMPLES**2)))
            else:
                px += bytes(4)
    header = bytes([0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0]) + struct.pack("<HH", SIZE, SIZE) + bytes([32, 0x28])
    return header + bytes(px)


def bag_layers():
    """A money bag: a tied sack with a gold coin (quest items to loot, on nameplates)."""

    def sack(pad):
        return union(
            ellipse(31, 41, 18 + pad, 16 + pad),
            polygon([(24 - pad, 31), (38 + pad, 31), (36 + pad, 22), (26 - pad, 22)]),
            ellipse(31, 18, 10 + pad, 5 + pad),
        )

    brown = lambda x, y: lerp((214, 164, 94), (128, 82, 36), (y - 13) / 44)
    return [
        (sack(1.8), lambda x, y: (52, 30, 10)),
        (sack(0), brown),
        (rounded(23, 23, 39, 27, 2), lambda x, y: (236, 196, 72)),  # the drawstring
        (ellipse(25, 38, 6, 7), lambda x, y: (238, 186, 104)),  # the light on the sack
        (ellipse(42, 47, 8.5, 8.5), lambda x, y: (96, 62, 8)),  # the coin's rim
        (ellipse(42, 47, 7, 7), lambda x, y: lerp((255, 226, 96), (214, 150, 20), (y - 40) / 14)),
    ]


def main():
    icons = (
        ("Kill", sword_layers()),
        ("Talk", bubble_layers()),
        ("Trash", trash_layers()),
        ("Loot", bag_layers()),
    )
    for name, layers in icons:
        path = os.path.join(OUT, name + ".tga")
        with open(path, "wb") as f:
            f.write(render(layers))
        print("wrote", os.path.normpath(path))


if __name__ == "__main__":
    main()
