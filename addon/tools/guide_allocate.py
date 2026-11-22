"""Give each quest of a chain of guides' zones to one guide of the chain.

    python3 -I addon/tools/guide_allocate.py <db> <ref.tsv> <out.json> <out.md> [<guides.json>]
        [--exclude <alloc.json> ...]

ref.tsv: the steps of Zygor's guides of the chain, converted (debug/zygor/dumpref.lua). The quests
Zygor hands in go to that guide; the quests of the guides' zones Zygor skips go to the guide whose
levels fit, chains kept in order. guides.json: [[title, from, to, [zone names]], ...] (default:
the Horde 40-60 chain). --exclude: allocations already made (their quests stay where they are).
"""
import json, re, sqlite3, sys, math
from collections import defaultdict

argv = [a for a in sys.argv[1:]]
excluded = set()
while "--exclude" in argv:
    i = argv.index("--exclude")
    excluded |= set(int(q) for q in json.load(open(argv[i + 1]))["quests"])
    del argv[i:i + 2]
sys.argv = [sys.argv[0]] + argv
db = sqlite3.connect(sys.argv[1])
rows = lambda sql, *a: db.execute(sql, a).fetchall()
one = lambda sql, *a: db.execute(sql, a).fetchone()

# The guides: title, levels, home zones (uiMap names).
GUIDES = [
    ("Riverglades (40-41)", 40, 41, ["Riverglades"]),
    ("Stranglethorn Vale & Swamp of Sorrows (41-43)", 41, 43, ["Stranglethorn Vale", "Swamp of Sorrows"]),
    ("Desolace & Shen'dralas (43-43)", 43, 43, ["Desolace", "Shen'dralas"]),
    ("Tanaris (43-43)", 43, 43, ["Tanaris"]),
    ("Dustwallow Marsh (43-44)", 43, 44, ["Dustwallow Marsh"]),
    ("Tanaris (44-44)", 44, 44, ["Tanaris"]),
    ("Riverglades (44-45)", 44, 45, ["Riverglades"]),
    ("Feralas (45-46)", 45, 46, ["Feralas"]),
    ("Stranglethorn Vale (46-47)", 46, 47, ["Stranglethorn Vale"]),
    ("Swamp of Sorrows (47-47)", 47, 47, ["Swamp of Sorrows"]),
    ("Tanaris & Dustwallow Marsh (47-48)", 47, 48, ["Tanaris", "Dustwallow Marsh"]),
    ("The Hinterlands (48-49)", 48, 49, ["The Hinterlands"]),
    ("Feralas & Un'Goro Crater (49-50)", 49, 50, ["Feralas", "Un'Goro Crater"]),
    ("Stranglethorn Vale & Swamp of Sorrows (50-50)", 50, 50, ["Stranglethorn Vale", "Swamp of Sorrows"]),
    ("Blasted Lands (50-51)", 50, 51, ["Blasted Lands"]),
    ("Searing Gorge (51-51)", 51, 51, ["Searing Gorge"]),
    ("Burning Steppes & Azshara (51-52)", 51, 52, ["Burning Steppes", "Azshara"]),
    ("Felwood & Winterspring (52-53)", 52, 53, ["Felwood", "Winterspring"]),
    ("Un'Goro Crater (53-54)", 53, 54, ["Un'Goro Crater"]),
    ("Azshara (54-54)", 54, 54, ["Azshara"]),
    ("Felwood & Winterspring (54-56)", 54, 56, ["Felwood", "Winterspring"]),
    ("Western & Eastern Plaguelands (56-58)", 56, 58, ["Western Plaguelands", "Eastern Plaguelands"]),
    ("Winterspring (58-59)", 58, 59, ["Winterspring"]),
    ("Silithus (59-60)", 59, 60, ["Silithus"]),
]

def area_of(name):
    r = one("select ID from client_areatable where AreaName_lang=? and ParentAreaID=0 order by ID", name)
    return int(r[0]) if r else None

if len(sys.argv) > 5:
    GUIDES = [tuple(g) for g in json.load(open(sys.argv[5]))]
LOW_LEVEL = min(g[1] for g in GUIDES) - 5

zone_area = {}
for g in GUIDES:
    for z in g[3]:
        zone_area[z] = area_of(z)
area_zone = {a: z for z, a in zone_area.items()}
missing = [z for z, a in zone_area.items() if a is None]
assert not missing, missing

# Zygor: where each quest is taken and handed in (guide index, 1-based).
z_acc, z_turn, z_obj = {}, {}, defaultdict(set)
for line in open(sys.argv[2], encoding="utf-8"):
    gi, title, k, q, m, x, y, only = line.rstrip("\n").split("\t")
    if not q:
        continue
    gi, q = int(gi), int(q)
    if k == "accept":
        z_acc.setdefault(q, gi)
    elif k == "turnin":
        z_turn.setdefault(q, gi)
    elif k == "objective":
        z_obj[q].add(gi)

HORDE = 178


def horde_ok(mask):
    if not mask:
        return True
    return bool(mask & HORDE) or bool(mask & (1 << 33))


# Dungeon areas (instances): their quests are left out.
instance_areas = set()
for (aid,) in rows("""select a.ID from client_areatable a join client_map m on m.ID = a.ContinentID
                       where a.ParentAreaID = 0 and m.InstanceType in (1, 2)"""):
    instance_areas.add(int(aid))


def quest_info(q):
    r = one("""select id, name, level, min_level, races_mask, classes_mask, zone_or_sort, status, in_client,
               special_flags, required_skill_id, next_in_chain from m_quest where id=?""", q)
    return r


def where(kind, eid):
    r = rows("select zone_id, count(*) from m_spawn where entity_type=? and entity_id=? group by zone_id order by 2 desc", kind, eid)
    return [int(z) for z, _ in r]


def relations(q, role):
    return rows("select entity_type, entity_id from m_quest_relation where quest_id=? and role=?", q, role)


# Candidate quests: starting or sorted in a home zone, for the Horde, in the game.
cands = {}
for z, a in zone_area.items():
    qs = {r[0] for r in rows("select id from m_quest where zone_or_sort=?", a)}
    qs |= {r[0] for r in rows("""select r.quest_id from m_quest_relation r join m_spawn s on s.entity_type=r.entity_type
                                  and s.entity_id=r.entity_id where s.zone_id=? and r.role='start'""", a)}
    for q in qs:
        cands.setdefault(q, set()).add(z)

reasons_out = {}
keep = {}
for q, zones in cands.items():
    r = quest_info(q)
    if not r:
        continue
    qid, name, level, minl, races, classes, sort, status, inc, special, skill, nxt = r
    why = None
    if status != "available":
        why = "not available (" + str(status) + ")"
    elif inc == 0:
        why = "not in the game client"
    elif not horde_ok(int(races or 0)):
        why = "Alliance only"
    elif classes:
        why = "class quest"
    elif skill:
        why = "profession quest"
    elif special and int(special) & 1:
        why = "repeatable"
    elif sort is not None and int(sort) < 0:
        why = f"category {sort} (class, profession, holiday or seasonal)"
    elif sort is not None and int(sort) in instance_areas:
        why = "dungeon quest"
    elif level is not None and 0 < level < LOW_LEVEL:
        why = f"low level ({level})"
    elif level is not None and level > 62:
        why = f"level {level}"
    if q in excluded:
        continue
    if why and q not in z_acc and q not in z_turn:
        reasons_out[q] = (name, level, ", ".join(sorted(zones)), why)
        continue
    keep[q] = {"id": q, "name": name, "level": level, "min": minl, "zones": sorted(zones)}

# Zygor's quests outside the home zones too (city hand-ins, breadcrumbs).
for q in set(z_acc) | set(z_turn):
    if q not in keep and q not in excluded:
        r = quest_info(q)
        if r:
            keep[q] = {"id": q, "name": r[1], "level": r[2], "min": r[3], "zones": []}

# Allocation.
alloc, notes = {}, defaultdict(list)
for q, info in keep.items():
    if q in z_turn or q in z_acc:
        g = z_turn.get(q) or z_acc.get(q)
        if q in z_acc and q not in z_turn and z_acc[q] == len(GUIDES):
            # Taken by the chain's last guide and handed in after it: a breadcrumb into the next
            # chain (e.g. into Riverglades): left to its taker.
            pass
        alloc[q] = g
        if q in z_acc and q in z_turn and z_acc[q] != z_turn[q]:
            notes[q].append(f"Zygor takes it in guide {z_acc[q]}, hands it in in guide {z_turn[q]}")
        if q in z_acc and q not in z_turn:
            notes[q].append(f"Zygor takes it in guide {z_acc[q]} and never hands it in")
        if q in z_turn and q not in z_acc:
            notes[q].append("Zygor hands it in, taken before Riverglades (40-41): carry" if z_turn[q] == 1
                            else f"Zygor hands it in in guide {z_turn[q]} without taking it in these guides")
        info["source"] = "zygor"
        continue
    level = info["level"] or info["min"] or 40
    best, score = None, None
    for gi, (title, lo, hi, zones) in enumerate(GUIDES, 1):
        if not set(zones) & set(info["zones"]):
            continue
        # Closest to the guide's levels; a little above them beats below (they will be by then).
        d = 0 if lo <= level <= hi else (lo - level) * 1.1 if level < lo else level - hi
        if score is None or d < score:
            best, score = gi, d
    if best is None:
        continue
    lo, hi = GUIDES[best - 1][1], GUIDES[best - 1][2]
    if not (lo - 4 <= level <= hi + 3):
        reasons_out[q] = (info["name"], level, ", ".join(info["zones"]),
                          f"level {level}: no visit of these guides fits (an earlier guide's quest)")
        continue
    alloc[q] = best
    info["source"] = "added"
    if score:
        notes[q].append(f"level {level} vs guide {GUIDES[best - 1][1]}-{GUIDES[best - 1][2]}")

# Chains: a quest never before its prerequisite's guide (when that guide visits its zone, else the
# next one that does).
links = defaultdict(list)
for q in alloc:
    for (p,) in rows("select other_id from m_quest_link where quest_id=? and kind in ('pre_all','pre_any')", q):
        if p in alloc:
            links[q].append(p)
changed = True
while changed:
    changed = False
    for q, ps in links.items():
        need = max(alloc[p] for p in ps)
        if alloc[q] < need and keep[q].get("source") == "added":
            zones = set(keep[q]["zones"])
            later = [gi for gi in range(need, len(GUIDES) + 1) if set(GUIDES[gi - 1][3]) & zones]
            if later:
                alloc[q] = later[0]
                notes[q].append("moved after its prerequisite")
                changed = True

out = {"guides": [{"index": i, "title": g[0], "levels": [g[1], g[2]], "zones": g[3]} for i, g in enumerate(GUIDES, 1)],
       "quests": {q: {**keep[q], "guide": alloc[q], "notes": notes.get(q, [])} for q in alloc},
       "left_out": {q: {"name": v[0], "level": v[1], "zones": v[2], "why": v[3]} for q, v in reasons_out.items()}}
json.dump(out, open(sys.argv[3], "w"), indent=1, default=str)

with open(sys.argv[4], "w") as md:
    md.write("# Horde guides 40-60: which guide takes each quest\n\n")
    md.write("Built from Zygor's Horde guides (where Zygor hands a quest in) and the game data (every Horde quest\n"
             "of the guides' zones Zygor skips, given to the visit whose levels fit). Each quest belongs to one\n"
             "guide: it is taken and handed in there.\n\n")
    for gi, g in enumerate(GUIDES, 1):
        qs = sorted((q for q in alloc if alloc[q] == gi), key=lambda q: (keep[q]["level"] or 0, q))
        md.write(f"## {gi}. {g[0]} — {len(qs)} quests\n\n")
        for q in qs:
            k = keep[q]
            tag = "" if k.get("source") == "zygor" else " **(added)**"
            n = ("; " + "; ".join(notes[q])) if notes.get(q) else ""
            md.write(f"- {q} {k['name']} (level {k['level']}){tag}{n}\n")
        md.write("\n")
    md.write("## Left out\n\n")
    for q, v in sorted(reasons_out.items(), key=lambda x: (x[1][2], x[0])):
        md.write(f"- {q} {v[0]} (level {v[1]}, {v[2]}): {v[3]}\n")
print({g[0]: sum(1 for q in alloc if alloc[q] == i) for i, g in enumerate(GUIDES, 1)})
print("added", sum(1 for q in alloc if keep[q].get("source") == "added"), "left out", len(reasons_out))
