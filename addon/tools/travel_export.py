#!/usr/bin/env python3
"""What takes a character across the world, for the addon's journeys: TravelData.lua.

The addon plans the fastest way to the place the guide points at (Journey.lua): on foot, by the
flight paths the character knows, by boat, zeppelin, tram and portal, and with the hearthstone.
This writes what it needs, in world yards (continent, north, west), from the app's own data:

    links    the transport links of overrides/travel.toml and overrides/<edition>/travel.toml
    nodes    the flight points of each faction (client_taxinodes)
    flights  the flight paths between them and their length (client_taxipath, client_taxipathnode)
    inns     where each inn of overrides/inns.toml binds the hearthstone (the innkeeper's spawn)
    speeds   the app's speeds and waits (crates/fg-route/src/params.rs defaults)

    python3 addon/tools/travel_export.py [--edition forever] [--check]
"""

import argparse
import math
import sys
import tomllib

import terrain_export as terrain

ROOT = terrain.ROOT
OUT = ROOT / "addon" / "Pathwright_Guide" / "TravelData.lua"
# The app's defaults (Params::default): yards a second on foot, the mount's bonus and level, the
# flight speed, the average wait for a boat or a zeppelin.
SPEEDS = {"run": 7.0, "mount": 0.6, "mountLevel": 40, "flight": 30.0, "wait": 120.0}
ALLIANCE, HORDE = 1, 2


class Zones:
    """Zone percent coordinates to world yards, from the client's map regions."""

    def __init__(self, con):
        self.regions = {}
        for area, continent, x0, y0, x1, y1 in con.execute(
            "SELECT AreaID, MapID, Region_0, Region_1, Region_3, Region_4 FROM client_uimapassignment"
            " WHERE OrderIndex = 0 ORDER BY UiMapID DESC"
        ):
            self.regions[int(area)] = (int(continent), float(x0), float(y0), float(x1), float(y1))

    def world(self, zone, x, y):
        """(continent, north, west) of the zone's point (x, y) in percent."""
        if zone not in self.regions:
            sys.exit(f"no map region for zone {zone}")
        continent, x0, y0, x1, y1 = self.regions[zone]
        return continent, x1 - y / 100.0 * (x1 - x0), y1 - x / 100.0 * (y1 - y0)


def faction_letter(name):
    return {"Horde": "H", "Alliance": "A"}.get(name)


def links(zones, edition):
    out = []
    for path in (ROOT / "overrides" / "travel.toml", ROOT / "overrides" / edition / "travel.toml"):
        if not path.exists():
            continue
        for link in tomllib.loads(path.read_text()).get("link", []):
            # A race's own way (a glide) is not a road for everyone.
            if link.get("races"):
                continue
            a = zones.world(link["from"]["zone"], link["from"]["x"], link["from"]["y"])
            b = zones.world(link["to"]["zone"], link["to"]["x"], link["to"]["y"])
            out.append(
                {
                    "name": link["name"],
                    "faction": faction_letter(link.get("faction")),
                    "from": a,
                    "to": b,
                    "seconds": link["seconds"],
                    "oneWay": bool(link.get("one_way")),
                    "instant": bool(link.get("instant")),
                    "quest": link.get("after_quest"),
                    "held": bool(link.get("while_held")),
                }
            )
    return out


def nodes(con):
    """The flight points a faction flies from: { id: (name, continent, north, west, faction) }."""
    out = {}
    for node, name, north, west, continent, flags in con.execute(
        "SELECT ID, Name_lang, Pos_0, Pos_1, ContinentID, Flags FROM client_taxinodes"
    ):
        flags = int(flags)
        sides = flags & (ALLIANCE | HORDE)
        if not sides or name.startswith(("zzOLD", "Quest Path", "Transport", "Generic")):
            continue
        faction = None if sides == (ALLIANCE | HORDE) else ("A" if sides == ALLIANCE else "H")
        out[int(node)] = (name, int(continent), float(north), float(west), faction)
    return out


def flights(con, known):
    """The flight paths between the points kept: [(from, to, yards)], the length flown."""
    lengths = {}
    last = {}
    for path, x, y, z in con.execute(
        "SELECT PathID, Loc_0, Loc_1, Loc_2 FROM client_taxipathnode ORDER BY PathID, NodeIndex"
    ):
        point = (float(x), float(y), float(z))
        if path in last:
            lengths[path] = lengths.get(path, 0.0) + math.dist(last[path], point)
        last[path] = point
    out = []
    for path, a, b in con.execute("SELECT ID, FromTaxiNode, ToTaxiNode FROM client_taxipath ORDER BY ID"):
        a, b = int(a), int(b)
        if a in known and b in known and a != b and lengths.get(path, 0) > 0:
            out.append((a, b, round(lengths[path])))
    return out


def inns(con, zones):
    """Where each inn binds: [(place, areas, continent, north, west)], the innkeeper's spawn."""
    listed = tomllib.loads((ROOT / "overrides" / "inns.toml").read_text())["inn"]
    out, seen = [], set()
    for inn in listed:
        spawn = con.execute(
            "SELECT zone_id, x, y FROM m_spawn WHERE entity_type = 'npc' AND entity_id = ? ORDER BY seen DESC LIMIT 1",
            (inn["npc"],),
        ).fetchone()
        if not spawn or spawn[0] not in zones.regions:
            continue
        continent, north, west = zones.world(spawn[0], spawn[1], spawn[2])
        if (inn["place"], continent) in seen:
            continue
        seen.add((inn["place"], continent))
        areas = [
            int(row[0])
            for row in con.execute(
                "SELECT ID FROM client_areatable WHERE AreaName_lang = ? ORDER BY ID", (inn["place"],)
            )
        ]
        out.append((inn["place"], areas, continent, north, west))
    return sorted(out)


def quote(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def number(v):
    return f"{v:.0f}"


def render(edition):
    con = terrain.database(edition)
    zones = Zones(con)
    lines = [
        "-- Built by addon/tools/travel_export.py from the app's travel data and the game data. Do not",
        "-- edit: change the data (overrides/travel.toml, overrides/inns.toml) and build again.",
        "Pathwright.TravelData = {",
        "    speeds = { "
        + ", ".join(f"{k} = {v:g}" for k, v in SPEEDS.items())
        + " },",
        "    -- { name, faction, continent, north, west, continent, north, west, seconds, one way,",
        "    -- instant (no wait), quest that opens it, only while that quest is held }",
        "    links = {",
    ]
    for link in links(zones, edition):
        a, b = link["from"], link["to"]
        fields = [
            quote(link["name"]),
            quote(link["faction"]) if link["faction"] else "false",
            str(a[0]),
            number(a[1]),
            number(a[2]),
            str(b[0]),
            number(b[1]),
            number(b[2]),
            f"{link['seconds']:g}",
            "true" if link["oneWay"] else "false",
            "true" if link["instant"] else "false",
            str(link["quest"]) if link["quest"] else "false",
            "true" if link["held"] else "false",
        ]
        lines.append("        { " + ", ".join(fields) + " },")
    lines += ["    },", "    -- [flight point] = { name, continent, north, west, faction }", "    nodes = {"]
    known = nodes(con)
    for node in sorted(known):
        name, continent, north, west, faction = known[node]
        lines.append(
            f"        [{node}] = {{ {quote(name)}, {continent}, {number(north)}, {number(west)}, "
            f"{quote(faction) if faction else 'false'} }},"
        )
    lines += ["    },", "    -- { from, to, yards flown }", "    flights = {"]
    row = []
    for a, b, yards in flights(con, known):
        row.append(f"{{ {a}, {b}, {yards} }}")
        if len(row) == 6:
            lines.append("        " + ", ".join(row) + ",")
            row = []
    if row:
        lines.append("        " + ", ".join(row) + ",")
    lines += ["    },", "    -- { the place the hearthstone names, its areas, continent, north, west }", "    inns = {"]
    for place, areas, continent, north, west in inns(con, zones):
        lines.append(
            f"        {{ {quote(place)}, {{ {', '.join(map(str, areas))} }}, {continent}, "
            f"{number(north)}, {number(west)} }},"
        )
    lines += ["    },", "}", ""]
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--edition", default="forever")
    ap.add_argument("--check", action="store_true", help="fail when the file is not up to date")
    args = ap.parse_args()
    text = render(args.edition)
    if args.check:
        if not OUT.exists() or OUT.read_text() != text:
            sys.exit(f"{OUT.relative_to(ROOT)} is not up to date: run addon/tools/travel_export.py")
        return
    OUT.write_text(text)
    print(f"{OUT.relative_to(ROOT)}: {len(text)} bytes")


if __name__ == "__main__":
    main()
