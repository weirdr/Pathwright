"""Research dossier of quests from the game data: givers and takers and where they stand,
objectives, where their mobs and objects spawn (groups, biggest first), who drops the items,
prerequisites. Coordinates are those of the area (zone) named before them.

    python3 -I addon/tools/guide_dossier.py data/forever.sqlite <area id> [quest id ...]

Without quest ids: every quest of that area (sorted there, or given or taken by someone in it).
"""
import sqlite3, sys, math

db = sqlite3.connect(sys.argv[1])
ZONE = int(sys.argv[2])
q1 = lambda sql, *a: db.execute(sql, a).fetchone()
qa = lambda sql, *a: db.execute(sql, a).fetchall()

if len(sys.argv) > 3:
    ids = [int(x) for x in sys.argv[3:]]
else:
    ids = [r[0] for r in qa("""
  select id from m_quest where zone_or_sort=? and status='available'
  union select r.quest_id from m_quest_relation r join m_spawn s on s.entity_type=r.entity_type
    and s.entity_id=r.entity_id join m_quest q on q.id=r.quest_id
    where s.zone_id=? and q.status='available'""", ZONE, ZONE)]


def name(kind, i):
    if kind == "npc":
        r = q1("select name from m_npc where id=?", i)
    elif kind == "object":
        r = q1("select name from m_object where id=?", i)
    else:
        r = q1("select name from m_item where id=?", i)
    return r[0] if r else f"{kind}#{i}"


def clusters(kind, i, k=3):
    pts = qa("select x,y from m_spawn where entity_type=? and entity_id=? and zone_id=?", kind, i, ZONE)
    pts = [(float(x), float(y)) for x, y in pts if x is not None]
    prefix = ""
    if not pts:
        other = qa("""select s.zone_id, a.AreaName_lang, count(*) n from m_spawn s left join client_areatable a
                      on a.ID = s.zone_id where entity_type=? and entity_id=? group by s.zone_id order by n desc""", kind, i)
        if not other:
            return "no spawn known"
        z, zname, _ = other[0]
        pts = [(float(x), float(y)) for x, y in qa(
            "select x,y from m_spawn where entity_type=? and entity_id=? and zone_id=?", kind, i, z) if x is not None]
        prefix = f"in {zname} ({z}) "
    groups = []
    for p in pts:
        for g in groups:
            cx, cy = g["sx"] / g["n"], g["sy"] / g["n"]
            if math.hypot(p[0] - cx, p[1] - cy) < 4:
                g["sx"] += p[0]; g["sy"] += p[1]; g["n"] += 1
                break
        else:
            groups.append({"sx": p[0], "sy": p[1], "n": 1})
    groups.sort(key=lambda g: -g["n"])
    return prefix + ", ".join(f"{g['sx']/g['n']:.1f},{g['sy']/g['n']:.1f}(x{g['n']})" for g in groups[:k]) + (
        f" +{len(groups)-k} more" if len(groups) > k else "")


def faction(mask):
    if not mask:
        return "both"
    a = mask & (1 << 32) or mask & 77
    h = mask & (1 << 33) or mask & 178
    return "both" if (a and h) else "A" if a else "H"


CLASSES = {1: "Warrior", 4: "Hunter", 8: "Rogue", 64: "Shaman", 128: "Mage", 1024: "Druid", 2: "Paladin", 16: "Priest", 256: "Warlock"}
out = []
for (qid,) in qa("select id from m_quest where id in (%s) order by level, id" % ",".join(map(str, ids))):
    q = q1("select name, level, min_level, races_mask, classes_mask, objectives_text, in_client, next_in_chain from m_quest where id=?", qid)
    nm, lvl, minl, races, classes, otext, inc, nxt = q
    cls = CLASSES.get(classes or 0, "") if classes else ""
    links = qa("select kind, other_id from m_quest_link where quest_id=?", qid)
    out.append(f"### {qid} {nm}  [lvl {lvl}, min {minl}, {faction(races)}{' ' + cls if cls else ''}{'' if inc else ', NOT IN CLIENT'}]")
    if links:
        out.append("  links: " + " ".join(f"{k}:{o}" for k, o in links) + (f"  next:{nxt}" if nxt else ""))
    for role in ("start", "end"):
        for kind, eid in qa("select entity_type, entity_id from m_quest_relation where quest_id=? and role=?", qid, role):
            out.append(f"  {role}: {kind} {eid} {name(kind, eid)} @ {clusters(kind, eid, 2)}")
    if otext:
        out.append("  text: " + " ".join(otext.split())[:300])
    for idx, typ, tid, amt, txt in qa("select idx, type, target_id, amount, text from m_quest_objective where quest_id=? order by idx", qid):
        kind = {"creature": "npc", "killcredit": "npc", "talk": "npc", "object": "object", "item": "item"}.get(typ)
        tname = name(kind, tid) if kind else (txt or tid)
        line = f"  obj{idx}: {typ} {amt or ''} {tname} ({tid})"
        if kind in ("npc", "object"):
            line += " @ " + clusters(kind, tid)
        out.append(line)
        if typ == "item":
            src = qa("""select from_type, from_id, chance from m_item_source i where item_id=? and (from_type not in ('npc','object')
                or exists (select 1 from m_spawn s where s.entity_type=i.from_type and s.entity_id=i.from_id and s.zone_id=?))
                order by chance desc""", tid, ZONE)
            if not src:
                out.append("      (no source in this zone; elsewhere:)")
                src = qa("select from_type, from_id, chance from m_item_source where item_id=? order by chance desc", tid)
            for ft, fid, ch in src[:6]:
                fk = {"npc": "npc", "object": "object"}.get(ft)
                where = clusters(fk, fid, 2) if fk else ""
                out.append(f"      from {ft} {fid} {name(fk or 'item', fid)} {ch if ch is not None else ''} @ {where}")
    si = q1("select source_item_id from m_quest where id=?", qid)
    if si and si[0]:
        out.append(f"  source item: {si[0]} {name('item', si[0])}")
print("\n".join(out))
