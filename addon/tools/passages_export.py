#!/usr/bin/env python3
"""The passages the walkable floors do not hold, for the addon: Terrain/Passages.lua.

The floors (terrain_export.py) come from the game's geometry: a lift, an elevator, a gate the
server opens are not part of it, and the ground on both sides stays apart. The app joins such
ground through hand-made passages (overrides/passes.toml); this writes those the floors need
(a lift, or sides in walkable areas the floors do not join) with the floor of each side, so
that the addon's walks (Walker.lua) cross them too.

    python3 addon/tools/passages_export.py [--edition forever] [--check]

Runs `fg terrain-overrides --sides` (target/release/fg, built with `cargo build --release -p
fg`) and reads data/<edition>.sqlite for the floors under each side.
"""

import argparse
import json
import pathlib
import subprocess
import sys
import tempfile

import terrain_export as terrain

ROOT = terrain.ROOT
OUT = ROOT / "addon" / "Pathwright_Guide" / "Terrain" / "Passages.lua"
# A side off the floors is taken to the nearest floor within this many cells.
REACH = 2


def sides(edition):
    """The passages as the app has them: `fg terrain-overrides --sides`."""
    fg = ROOT / "target" / "release" / "fg"
    with tempfile.TemporaryDirectory() as tmp:
        path = pathlib.Path(tmp) / "sides.json"
        subprocess.run(
            [str(fg), "terrain-overrides", "--edition", edition, "--sides", str(path)],
            cwd=ROOT,
            check=True,
            capture_output=True,
        )
        return json.loads(path.read_text())


class Floors:
    """The floors of the cells asked for, a tile read once."""

    def __init__(self, edition):
        self.con = terrain.database(edition)
        self.tiles = {}

    def tile(self, map_id, tr, tc):
        key = (map_id, tr, tc)
        if key not in self.tiles:
            row = self.con.execute(
                "SELECT data FROM client_terrain_layers WHERE map_id = ? AND tile_x = ? AND tile_y = ?",
                (map_id, tc, tr),
            ).fetchone()
            self.tiles[key] = terrain.decode(next(terrain.unzstd([row[0]]))) if row else None
        return self.tiles[key]

    def standable(self, map_id, r, c):
        """The floors of cell (r, c) that can be stood on: [(floor, height or None), ...]."""
        tile = self.tile(map_id, r >> 6, c >> 6)
        if tile is None:
            return []
        counts, offsets, heights, water, _, _, _ = tile
        i = (r & 63) * 64 + (c & 63)
        out = []
        for k in range(counts[i]):
            f = offsets[i] + k
            if not water[f] & (terrain.HAZARD | terrain.DEEP):
                out.append((k, heights[f] if counts[i] > 1 else None))
        return out

    def node(self, map_id, x, y, z):
        """The floor under a side: (row, column, floor), the nearest to height `z` where the
        cell has several; None without any within REACH cells."""
        row, column = int((terrain.ORIGIN - x) // terrain.CELL), int((terrain.ORIGIN - y) // terrain.CELL)
        best = None
        for reach in range(REACH + 1):
            for r in range(row - reach, row + reach + 1):
                for c in range(column - reach, column + reach + 1):
                    if max(abs(r - row), abs(c - column)) != reach:
                        continue
                    for floor, height in self.standable(map_id, r, c):
                        gap = abs(height - z) if height is not None and z is not None else 0
                        far = (r - row) ** 2 + (c - column) ** 2
                        if best is None or (gap, far) < best[0]:
                            best = ((gap, far), (r, c, floor))
            if best is not None:
                return best[1]
        return None


def build(edition):
    floors = Floors(edition)
    lines = [
        "-- The passages the walkable floors do not hold (addon/tools/passages_export.py): do not edit.",
        "-- A lift, an elevator, a gate: `sides` are the floors it joins, each { node, north, west }",
        "-- (a node: Terrain.lua), walked between through `at`.",
        "Pathwright.Passages = {",
    ]
    kept = 0
    for p in sides(edition):
        areas = {s["area"] for s in p["sides"]}
        if p["shortcut"] or len(p["sides"]) < 2 or not (len(areas) > 1 or p["lift"]):
            continue
        ends = []
        for s in p["sides"]:
            node = floors.node(p["continent"], s["x"], s["y"], s["z"])
            if node is None:
                print(f"{p['name']}: no floor under a side at {s['x']:.0f}, {s['y']:.0f}", file=sys.stderr)
                continue
            r, c, f = node
            ends.append(f"{{ {(r * 4096 + c) * 8 + f}, {s['x']:.1f}, {s['y']:.1f} }}")
        if len(ends) < 2:
            continue
        kept += 1
        name = p["name"].replace("\\", "\\\\").replace('"', '\\"')
        lines.append(
            f'    {{ name = "{name}", map = {p["continent"]}, lift = {"true" if p["lift"] else "false"}, '
            f'at = {{ {p["x"]:.1f}, {p["y"]:.1f} }}, sides = {{ {", ".join(ends)} }} }},'
        )
    lines.append("}")
    return "\n".join(lines) + "\n", kept


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--edition", default="forever")
    parser.add_argument("--check", action="store_true", help="fail when the file is not up to date")
    args = parser.parse_args()
    text, kept = build(args.edition)
    if args.check:
        if not OUT.exists() or OUT.read_text() != text:
            sys.exit("Terrain/Passages.lua is not up to date")
        print("Terrain/Passages.lua is up to date")
        return
    OUT.write_text(text)
    print(f"wrote {kept} passages to {OUT}")


if __name__ == "__main__":
    main()
