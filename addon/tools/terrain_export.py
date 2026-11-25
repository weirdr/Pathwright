#!/usr/bin/env python3
"""The walkable ground of the game, for the addon: addon/Pathwright_Guide/Terrain/*.lua.

The app finds its walks on floors made from the game's geometry (crates/fg-route/src/terrain:
cells of 8.33 yards, up to 8 floors in each, the steps between them). This writes the same
floors and steps for the addon, which walks them in game from where the character stands
(Terrain.lua, Walker.lua): one string a tile, deflated then in base 64.

    python3 addon/tools/terrain_export.py [--edition forever] [--check]

Reads data/<edition>.sqlite (unpacked from data/<edition>.sqlite.zst when it is missing) and
overrides/passes.toml (the ways closed in the game). Needs the `zstd` command.

A tile, before it is deflated (little-endian):

    u8      format (FORMAT)
    u16     full: the first floors with a full record
    4096    for each cell, the steps of its first floor to its neighbours' first floors: bit d
            for direction d (north, south, west, east, north-west, north-east, south-west,
            south-east), a drop it can take one way among them
    4096    for each cell, its first floor's flags (FLAG_*; what the floor is only in a cell
            of several floors, where it tells them apart)
    multi   for each cell with more floors (FLAG_MULTI), in order: how many floors it has
    extra   for each other floor of those cells, in order: its flags
    9*(full+extra)  the full records, first floors (FLAG_FULL, in cell order) then the other
            floors: for each direction the floors of that neighbour stepped to (bit j: its
            floor j), then the floors of the same cell dropped to

A step is taken only to a floor that can be stood on (its flag): the records do not say.
"""

import argparse
import base64
import pathlib
import re
import sqlite3
import struct
import subprocess
import sys
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "addon" / "Pathwright_Guide" / "Terrain"
FORMAT = 1
# A cell's side and the world's corner (crates/fg-route/src/terrain/mod.rs).
TILE = 1600.0 / 3.0
CELL = TILE / 64.0
ORIGIN = 32.0 * TILE
# A floor's flags: stood on, swum, with a full record, in a cell of several floors; then what
# the floor is (the layers' own flags: the terrain's surface, under it, above it, on a model).
FLAG_STAND, FLAG_SWIM, FLAG_FULL, FLAG_MULTI = 1, 2, 4, 8
KIND_SHIFT = 4
# Water: wet, a hazard (magma, slime), deep (the open sea); its depth in the bits above.
WET, HAZARD, DEEP = 1, 2, 4
SWIM_DEPTH = 2
DIRS = [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (-1, 1), (1, -1), (1, 1)]
OPP = [1, 0, 3, 2, 7, 6, 5, 4]
VIAS = [[(0, 2), (2, 0)], [(0, 3), (3, 0)], [(1, 2), (2, 1)], [(1, 3), (3, 1)]]
# Lua files of about this many characters.
CHUNK = 600_000


def unzigzag(v):
    return (v >> 1) ^ -(v & 1)


def clamp(v):
    return max(-32768, min(32767, v))


def predict_height(a, b, c, last):
    if a is not None and b is not None and c is not None:
        lo, hi = min(a, b), max(a, b)
        if c >= hi:
            return lo
        if c <= lo:
            return hi
        return clamp(a + b - c)
    if a is not None:
        return a
    if b is not None:
        return b
    return last


def decode(raw):
    """A tile's layers (layers.rs `unpack_v2`): counts, offsets, heights, water, flags, walks,
    drops (the first tier: no damage)."""
    version = raw[0]
    assert version in (2, 3, 4, 5), version
    lean, farther = version in (3, 5), version in (4, 5)
    counts = raw[1:4097]
    at = 4097
    offsets = [0] * 4097
    n = 0
    for i in range(4096):
        offsets[i] = n
        n += counts[i]
    offsets[4096] = n
    heights = [0] * n

    def varint():
        nonlocal at
        v = s = 0
        while True:
            b = raw[at]
            at += 1
            v |= (b & 0x7F) << s
            if b < 0x80:
                return v
            s += 7

    def first(j):
        if counts[j] > 0 and not (lean and counts[j] == 1):
            return heights[offsets[j]]
        return None

    last = 0
    for i in range(4096):
        if counts[i] == 0 or (lean and counts[i] == 1):
            continue
        r, c = divmod(i, 64)
        a = first(i - 1) if c > 0 else None
        b = first(i - 64) if r > 0 else None
        nw = first(i - 65) if (r > 0 and c > 0) else None
        h = clamp(predict_height(a, b, nw, last) + unzigzag(varint()))
        heights[offsets[i]] = h
        last = h
    for i in range(4096):
        lo, hi = offsets[i], offsets[i + 1]
        for k in range(min(lo + 1, hi), hi):
            heights[k] = clamp(heights[lo] + unzigzag(varint()))
    water = raw[at : at + n]
    at += n
    flags = raw[at : at + n]
    at += n
    if not lean:
        at += n
    straight = raw[at : at + 4 * n]
    at += 4 * n
    walks = [[0] * 8 for _ in range(n)]
    for i in range(4096):
        r, c = divmod(i, 64)
        for k in range(counts[i]):
            f = offsets[i] + k
            for d in range(4):
                dr, dc = DIRS[d]
                nr, nc = r + dr, c + dc
                if not (0 <= nr < 64 and 0 <= nc < 64):
                    p = 1 if k == 0 else 0
                else:
                    nn = nr * 64 + nc
                    lo, hi = offsets[nn], offsets[nn + 1]
                    if d in (0, 2):
                        p = 0
                        for j in range(lo, hi):
                            if walks[j][OPP[d]] >> k & 1:
                                p |= 1 << (j - lo)
                    else:
                        h = heights[f]
                        best = None
                        for j in range(lo, hi):
                            t = (abs(heights[j] - h), j - lo)
                            if best is None or t < best:
                                best = t
                        p = (1 << best[1]) if (best is not None and best[0] <= 4) else 0
                walks[f][d] = straight[4 * f + d] ^ p
    diagonal = raw[at : at + 4 * n]
    at += 4 * n
    for i in range(4096):
        r, c = divmod(i, 64)
        for k in range(counts[i]):
            f = offsets[i] + k
            wf = walks[f]
            for slot in range(4):
                dr, dc = DIRS[4 + slot]
                bits = 0
                for w, (dv, dn) in enumerate(VIAS[slot]):
                    vr, vc = (r + dr, c) if w == 0 else (r, c + dc)
                    if not (0 <= vr < 64 and 0 <= vc < 64) or wf[dv] == 0:
                        continue
                    v = vr * 64 + vc
                    for j in range(offsets[v], offsets[v + 1]):
                        if wf[dv] >> (j - offsets[v]) & 1:
                            bits |= walks[j][dn]
                wf[4 + slot] = diagonal[4 * f + slot] ^ bits
    drops = [[0] * 5 for _ in range(n)]
    slots = raw[at : at + n]
    at += n
    for f in range(n):
        s = slots[f]
        for k in range(5):
            if s >> k & 1:
                drops[f][k] = raw[at]
                at += 1
    if farther:
        # The drops that cost health: not walked in game.
        for _ in range(2):
            slots = raw[at : at + n]
            at += n
            for f in range(n):
                s = slots[f]
                for k in range(5):
                    if s >> k & 1:
                        at += 1
    assert at == len(raw), (at, len(raw))
    return counts, offsets, heights, water, flags, walks, drops


def closed_points():
    """The ways closed in the game (overrides/passes.toml `[[closed]]` with `world`):
    (continent, x, y, radius)."""
    text = (ROOT / "overrides" / "passes.toml").read_text()
    out = []
    for block in text.split("[[closed]]")[1:]:
        block = block.split("[[", 1)[0]
        world = re.search(r"^world\s*=\s*\[\s*(-?\d+)\s*,\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*\]", block, re.M)
        radius = re.search(r"^radius\s*=\s*([\d.]+)", block, re.M)
        if world and radius:
            out.append((int(world[1]), float(world[2]), float(world[3]), float(radius[1])))
    return out


def pack(map_id, tx, ty, layers, closed):
    """A tile for the addon (see the top), None when nothing of it can be stood on."""
    counts, offsets, heights, water, flags, walks, drops = layers

    def closed_at(i):
        r, c = ty * 64 + i // 64, tx * 64 + i % 64
        x, y = ORIGIN - (r + 0.5) * CELL, ORIGIN - (c + 0.5) * CELL
        return any(m == map_id and (x - cx) ** 2 + (y - cy) ** 2 <= rad * rad for m, cx, cy, rad in closed)

    def floor_flags(i, k, shut):
        f = offsets[i] + k
        w = water[f]
        out = (flags[f] & 15) << KIND_SHIFT if counts[i] > 1 else 0
        if not shut and not w & (HAZARD | DEEP):
            out |= FLAG_STAND
            if w & WET and w >> 3 >= SWIM_DEPTH:
                out |= FLAG_SWIM
        return out

    def record(f):
        w, d = walks[f], drops[f]
        return bytes([w[0] | d[0], w[1] | d[1], w[2] | d[2], w[3] | d[3], w[4], w[5], w[6], w[7], d[4]])

    masks, first = bytearray(4096), bytearray(4096)
    multi, extra, full_first, full_extra = bytearray(), bytearray(), bytearray(), bytearray()
    n_full = 0
    standable = False
    for i in range(4096):
        count = counts[i]
        if count == 0:
            continue
        shut = bool(closed) and closed_at(i)
        fl = floor_flags(i, 0, shut)
        if fl & FLAG_STAND:
            standable = True
            rec = record(offsets[i])
            mask = 0
            for d in range(8):
                if rec[d] & 1:
                    mask |= 1 << d
            masks[i] = mask
            if rec[8] or any(b & 0xFE for b in rec[:8]):
                fl |= FLAG_FULL
                full_first += rec
                n_full += 1
        if count > 1:
            fl |= FLAG_MULTI
            multi.append(count)
            for k in range(1, count):
                efl = floor_flags(i, k, shut) | FLAG_FULL | FLAG_MULTI
                if efl & FLAG_STAND:
                    standable = True
                    full_extra += record(offsets[i] + k)
                else:
                    full_extra += bytes(9)
                extra.append(efl)
        first[i] = fl
    if not standable:
        return None
    return (
        struct.pack("<BH", FORMAT, n_full)
        + bytes(masks)
        + bytes(first)
        + bytes(multi)
        + bytes(extra)
        + bytes(full_first)
        + bytes(full_extra)
    )


def database(edition):
    path = ROOT / "data" / f"{edition}.sqlite"
    if not path.exists():
        subprocess.run(["zstd", "-dk", str(path) + ".zst", "-o", str(path)], check=True)
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True)


def unzstd(blobs):
    """Each blob inflated (the `zstd` command, one process a blob)."""
    for blob in blobs:
        yield subprocess.run(["zstd", "-dc"], input=blob, capture_output=True, check=True).stdout


def build(edition, only=None):
    """The Lua files' texts by name."""
    con = database(edition)
    rows = con.execute(
        "SELECT map_id, tile_x, tile_y, data FROM client_terrain_layers ORDER BY map_id, tile_y, tile_x"
    ).fetchall()
    if only is not None:
        rows = [row for row in rows if row[0] == only]
    closed = closed_points()
    entries, raw_size = [], 0
    for index, ((map_id, tx, ty, _), raw) in enumerate(zip(rows, unzstd(row[3] for row in rows))):
        tile = pack(map_id, tx, ty, decode(raw), closed)
        if tile is None:
            continue
        raw_size += len(tile)
        text = base64.b64encode(zlib.compress(tile, 9)).decode()
        entries.append((map_id, ty, tx, text))
        if index % 100 == 0:
            print(f"  {index}/{len(rows)} tiles", file=sys.stderr)
    files, chunk, size, number = {}, [], 0, 1

    def flush():
        nonlocal chunk, size, number
        if not chunk:
            return
        lines = [
            "-- The walkable ground of the game (addon/tools/terrain_export.py): do not edit.",
            f"-- Edition {edition}, format {FORMAT}. A tile: deflated, in base 64 (see Terrain.lua).",
            "local D = Pathwright.TerrainData",
        ]
        for map_id, ty, tx, text in chunk:
            lines.append(f'D["{map_id}:{ty}:{tx}"] = "{text}"')
        files[f"Tiles{number}.lua"] = "\n".join(lines) + "\n"
        chunk, size, number = [], 0, number + 1

    for entry in entries:
        chunk.append(entry)
        size += len(entry[3])
        if size >= CHUNK:
            flush()
    flush()
    maps = sorted({e[0] for e in entries})
    header = [
        "-- The walkable ground of the game (addon/tools/terrain_export.py): do not edit.",
        f"-- {len(entries)} tiles of maps {', '.join(map(str, maps))}; {raw_size} bytes before they are deflated.",
        "Pathwright.TerrainData = {}",
        f"Pathwright.TerrainFormat = {FORMAT}",
    ]
    files = {"Tiles0.lua": "\n".join(header) + "\n", **files}
    return files


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--edition", default="forever")
    parser.add_argument("--map", type=int, default=None, help="only this map (to try)")
    parser.add_argument("--out", default=str(OUT))
    parser.add_argument("--check", action="store_true", help="fail when the files are not up to date")
    args = parser.parse_args()
    files = build(args.edition, args.map)
    out = pathlib.Path(args.out)
    if args.check:
        stale = [name for name, text in files.items() if not (out / name).exists() or (out / name).read_text() != text]
        extra = [p.name for p in out.glob("Tiles*.lua") if p.name not in files]
        if stale or extra:
            sys.exit(f"terrain files not up to date: {', '.join(stale + extra)}")
        print("terrain files are up to date")
        return
    out.mkdir(parents=True, exist_ok=True)
    for old in out.glob("Tiles*.lua"):
        old.unlink()
    for name, text in files.items():
        (out / name).write_text(text)
    total = sum(len(text) for text in files.values())
    print(f"wrote {len(files)} files, {total} characters, to {out}")


if __name__ == "__main__":
    main()
