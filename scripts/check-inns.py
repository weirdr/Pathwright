#!/usr/bin/env python3
"""Fails when an innkeeper of the game data (a creature titled "Innkeeper" with a spawn, which the
planner can send a player to bind with) is in neither list of overrides/inns.toml: `[[inn]]` (its
place is known) or `[[left_out]]` (left out on purpose). Also fails on a listed npc that is no
innkeeper with a spawn in any database, and on an `[[inn]]` place with no AreaTable row. Reads the databases of data/, which must be
unpacked first: scripts/check-inns.py [classic.sqlite tbc.sqlite forever.sqlite]. Without arguments
it unpacks data/*.sqlite.zst to a temporary folder."""
import os
import sqlite3
import subprocess
import sys
import tempfile
import tomllib

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
with open(os.path.join(root, "overrides", "inns.toml"), "rb") as f:
    toml = tomllib.load(f)
known = {i["npc"] for i in toml["inn"]} | {i["npc"] for i in toml.get("left_out", [])}
both = {i["npc"] for i in toml["inn"]} & {i["npc"] for i in toml.get("left_out", [])}
if both:
    sys.exit(f"overrides/inns.toml: listed and left out at once: {sorted(both)}")

dbs = sys.argv[1:]
tmp = tempfile.TemporaryDirectory()
if not dbs:
    for e in ("classic", "tbc", "forever"):
        out = os.path.join(tmp.name, e + ".sqlite")
        subprocess.run(["zstd", "-dqf", os.path.join(root, "data", e + ".sqlite.zst"), "-o", out], check=True)
        dbs.append(out)

places = {i["npc"]: i["place"] for i in toml["inn"]}
missing = {}
errors = []
seen_npc, seen_place = set(), set()
for db in dbs:
    conn = sqlite3.connect(db)
    for i in known:
        if conn.execute(
            "select 1 from m_npc where id = ? and subname = 'Innkeeper' "
            "and exists (select 1 from m_spawn where entity_id = m_npc.id)", (i,)
        ).fetchone():
            seen_npc.add(i)
    for place in set(places.values()):
        if conn.execute("select 1 from client_areatable where AreaName_lang = ?", (place,)).fetchone():
            seen_place.add(place)
    for i, name in conn.execute(
        "select id, name from m_npc where subname = 'Innkeeper' "
        "and exists (select 1 from m_spawn where entity_id = m_npc.id)"
    ):
        if i not in known:
            missing[i] = name
for i, name in sorted(missing.items()):
    print(f"innkeeper {i} ({name}): add it to overrides/inns.toml, as [[inn]] or [[left_out]]")
for i in sorted(known - seen_npc):
    errors.append(f"npc {i} of overrides/inns.toml is no innkeeper with a spawn in any database")
for i, place in sorted(places.items()):
    if place not in seen_place:
        errors.append(f"npc {i}: place {place!r} has no client_areatable row in any database, so the bind step would lose `inn`/`ia`")
for e in errors:
    print(e)
sys.exit(1 if missing or errors else 0)
