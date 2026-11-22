#!/usr/bin/env python3
"""Build a built-in Pathwright guide from an authored guide script and the game data.

    python3 addon/tools/guide_build.py addon/guides/skyborne_starter.guide \
        [--db data/forever.sqlite.zst] [--out addon/Pathwright_Guide/Builtin]

The script (addon/guides/*.guide) says the order: which quests to take, do and hand in, where to
train, sell or set the hearthstone. The game data (data/forever.sqlite.zst) fills in the rest: who
gives and takes each quest and where they stand, what each objective needs, where its mobs or
objects are, who drops its items, the levels, the prerequisites. A quest made for one faction or
class is kept for those characters only.

Script lines (one step each, "#" starts a comment, blank lines are ignored):

    guide <name>                  the guide's name in the addon
    map <uiMap name>              the zone of what follows: its coordinates, and where NPCs, mobs
                                  and objects are looked for first
    races <race id> ...           the races it is for: one variant per race and class
    faction horde|alliance        or every race of a faction (a zone guide)
    levels <from> <to>
    next <guide name>             the guide that follows (the addon opens it when this one ends)
    carry <quest> ...             quests taken in the guide before, handed in here
    leave <quest> ...             quests taken here and handed in by the next guide (breadcrumbs)

    accept <quest> [<quest>...]   take the quests (one step each)
    turnin <quest> [<quest>...]   hand them in
    do <quest>[.<objective>]      do its objectives (all of them, or the one given)
    train <npc> [<npc>...]        class trainers: one step each, for their class only
    sell <npc> / bind <npc>       a vendor, an innkeeper
    fpath <npc>                   learn a flight path from a flight master
    fly <node name> npc <npc>     take a flight from the flight master <npc> to a node
    hearth npc <innkeeper>        use the hearthstone (done near that inn)
    ah <quest>.<objective> npc <auctioneer>
                                  offer to buy a quest's items at the auction house instead of
                                  farming them: optional (along the way), done once the bags hold
                                  them, so farming them later completes it too; it may come before
                                  the quest is taken (addon/tools/guide_ah.py lists the candidates)
    note <text>                   something to do by hand (marked done)
    goto <text>                   a place to reach (needs "at")
    grind <level>                 kill on the way until that level
    tip <text>                    a tip on the step before (the whole line)

Options after a step, in any order:

    at <x>,<y>      the place (else the data's: the NPC, the main group of its mobs)
    in <uiMap>      the map of "at" for this step only
    mobs <npc>...   the mobs of an objective (else the data's); makes a count-less one a kill
    r <yards>       how close a "goto" is reached
    bg              an objective done along the way, while doing the steps after it
    icon <icon>     the step's icon (talk, use, kill, get, pickup, text...); not kill: no mobs
    nopre           take no prerequisite from the data (when it is wrong)
    only <who>...   alliance, horde and class names (warrior, mage...): who the step is for
    npc <npc>       the NPC of a note, or who takes a quest handed in (its name and place)
    "<text>"        the step's text (tip, note and goto take the rest of the line)

Checks: the build stops on a quest taken and never handed in (unless left to the next guide), a
quest handed in without being taken or before its objectives are done, a quest log over 40 (the
game's limit, the quests carried in counted; over 36 warns), and warns of a quest taken
at a giver met earlier in the guide while it could already be taken there (take everything a hub
gives at once), and of a quest taken whose objectives no step does.
"""
import argparse, math, os, re, shlex, sqlite3, subprocess, sys, tempfile, time

ap = argparse.ArgumentParser()
ap.add_argument("script")
ap.add_argument("--db", default="data/forever.sqlite.zst")
ap.add_argument("--out", default="addon/Pathwright_Guide/Builtin")
args = ap.parse_args()

# The game data (zstd compressed in the repository).
if args.db.endswith(".zst"):
    tmp = tempfile.NamedTemporaryFile(suffix=".sqlite", delete=False)
    tmp.close()
    subprocess.run(["zstd", "-dqf", args.db, "-o", tmp.name], check=True)
    dbpath = tmp.name
else:
    dbpath, tmp = args.db, None
db = sqlite3.connect(dbpath)
one = lambda sql, *a: db.execute(sql, a).fetchone()
rows = lambda sql, *a: db.execute(sql, a).fetchall()

CLASS_BITS = {1: 1, 2: 2, 3: 4, 4: 8, 5: 16, 7: 64, 8: 128, 9: 256, 11: 1024}
CLASS_IDS = {"warrior": 1, "paladin": 2, "hunter": 3, "rogue": 4, "priest": 5, "shaman": 7, "mage": 8,
             "warlock": 9, "druid": 11}
# Skill lines of the professions (the Camping 101 quests are for one each).
PROFESSION_LINES = {"Alchemy": 171, "Blacksmithing": 164, "Cooking": 185, "Enchanting": 333,
                    "Engineering": 202, "First Aid": 129, "Fishing": 356, "Herbalism": 182,
                    "Leatherworking": 165, "Mining": 186, "Skinning": 393, "Tailoring": 197}


def fail(line_no, msg):
    sys.exit(f"{args.script}:{line_no}: {msg}")


# Maps: uiMap by name (zones: Type 3, not a system copy), and the uiMap of an area of the data.
uimap = {}
for mid, name, typ, system in rows("select ID, Name_lang, Type, System from client_uimap order by ID"):
    if str(typ) == "3" and str(system) == "0" and name not in uimap:
        uimap[name] = int(mid)
area_map = {}
for aid, name in rows("select ID, AreaName_lang from client_areatable"):
    if name in uimap:
        area_map[int(aid)] = uimap[name]

# Races and their classes.
WARNINGS = []


def warn(line_no, msg):
    WARNINGS.append(f"{args.script}:{line_no}: warning: {msg}")



race_faction = {int(r): ("Horde" if str(a) == "1" else "Alliance") for r, a in rows("select ID, Alliance from client_chrraces")}
race_classes = {}
for r, c in rows("select RaceID, ClassID from client_charbaseinfo order by ClassID"):
    race_classes.setdefault(int(r), []).append(int(c))


def name_of(kind, i):
    table = {"npc": "m_npc", "object": "m_object", "item": "m_item"}[kind]
    r = one(f"select name from {table} where id=?", i)
    return " ".join(r[0].split()) if r and r[0] else f"{kind} {i}"


def spawns(kind, i, area):
    return [(float(x), float(y)) for x, y in rows(
        "select x, y from m_spawn where entity_type=? and entity_id=? and zone_id=? and x is not null", kind, i, area)]


def groups(points, radius=4.0):
    """Points grouped by distance, biggest group first: [(x, y, count)]."""
    out = []
    for x, y in points:
        for g in out:
            if math.hypot(x - g[0] / g[2], y - g[1] / g[2]) < radius:
                g[0] += x; g[1] += y; g[2] += 1
                break
        else:
            out.append([x, y, 1])
    out.sort(key=lambda g: -g[2])
    return [(round(g[0] / g[2], 2), round(g[1] / g[2], 2), g[2]) for g in out]


def best_area(kind, i):
    """The area (of a known map) where an NPC, object... spawns the most, None when none."""
    rs = rows("""select zone_id, count(*) n from m_spawn where entity_type=? and entity_id=? and x is not null
                 group by zone_id order by n desc""", kind, i)
    for z, _ in rs:
        if int(z) in area_map:
            return int(z)
    return None


def place_of(kind, i, prefer_area):
    """(uiMap, x, y) of an NPC or object: in the zone of the moment when it spawns there, else
    where it spawns the most."""
    for a in (prefer_area, best_area(kind, i)):
        if a is None:
            continue
        pts = spawns(kind, i, a)
        if pts:
            x, y, _ = groups(pts)[0]
            return area_map[a], x, y
    return None


def area_of_map(name):
    r = one("select ID from client_areatable where AreaName_lang=? and ParentAreaID=0 order by ID", name)
    return int(r[0]) if r else None


# The script ---------------------------------------------------------------------------------------

guide = {"name": None, "races": [], "from": 1, "to": 60, "next": None}
carried, left = set(), set()
lines = []
for n, raw in enumerate(open(args.script, encoding="utf-8"), 1):
    text = raw.split(" #")[0].strip() if not raw.lstrip().startswith(("note", "tip", "goto")) else raw.strip()
    if not text or text.startswith("#"):
        continue
    lines.append((n, text))

current_map = None
area = None  # the data's area of the guide's zone
steps = []


def variants_all():
    out = []
    for r in guide["races"]:
        for c in race_classes.get(r, []):
            out.append({"race": r, "class": c, "faction": race_faction[r]})
    return out


def parse_opts(n, words, quiet=False):
    if quiet:
        def fail(_, msg):
            raise ValueError(msg)
    else:
        fail_ = globals()["fail"]

        def fail(line_no, msg):
            fail_(line_no, msg)
    o = {"only": [], "mobs": None}
    i = 0
    while i < len(words):
        w = words[i]
        if w in ("at", "in", "r", "icon", "npc") and i + 1 >= len(words):
            fail(n, w + " needs a value")
        if w == "at":
            m = re.match(r"^(\d+(?:\.\d+)?),(\d+(?:\.\d+)?)$", words[i + 1])
            if not m:
                fail(n, "at x,y expected")
            o["at"] = (float(m.group(1)), float(m.group(2)))
            i += 2
        elif w == "in":
            o["in"] = uimap.get(words[i + 1].replace("_", " ")) or fail(n, "unknown map " + words[i + 1])
            i += 2
        elif w == "r":
            if not re.match(r"^\d+(\.\d+)?$", words[i + 1]):
                fail(n, "r <yards>")
            o["r"] = float(words[i + 1]); i += 2
        elif w == "bg":
            o["bg"] = True; i += 1
        elif w == "nopre":
            o["nopre"] = True; i += 1
        elif w == "icon":
            o["icon"] = words[i + 1]; i += 2
        elif w == "npc":
            if not words[i + 1].isdigit():
                fail(n, "npc <id>")
            o["npc"] = int(words[i + 1]); i += 2
        elif w == "mobs":
            o["mobs"] = []
            i += 1
            while i < len(words) and words[i].isdigit():
                o["mobs"].append(int(words[i])); i += 1
        elif w == "only":
            i += 1
            start = i
            while i < len(words) and words[i].lower() in ("alliance", "horde", *CLASS_IDS):
                o["only"].append(words[i].lower()); i += 1
            if i == start:
                fail(n, "only <faction or class>")
        elif " " in w and not quiet:
            o["t"] = w; i += 1
        else:
            fail(n, "unknown option " + w)
    return o


OPTION_WORDS = {"at", "in", "r", "bg", "nopre", "icon", "npc", "mobs", "only"}


def opts_ok(words):
    """Whether these words read as options."""
    try:
        parse_opts(0, words, quiet=True)
        return True
    except ValueError:
        return False


def who(only_words):
    """The variant filter of "only" words: factions and classes (a class list is any of them)."""
    factions = {w.capitalize() for w in only_words if w in ("alliance", "horde")}
    classes = {CLASS_IDS[w] for w in only_words if w in CLASS_IDS}
    return lambda v: (not factions or v["faction"] in factions) and (not classes or v["class"] in classes)


def quest(qid, n):
    r = one("""select name, level, min_level, races_mask, classes_mask, objectives_text, zone_or_sort
               from m_quest where id=?""", qid)
    if not r:
        fail(n, f"quest {qid} is not in the game data")
    name, level, minl, races, classes, otext, sort = r
    pre = [o for (o,) in rows("select other_id from m_quest_link where quest_id=? and kind='pre_all'", qid)]
    pa = [o for (o,) in rows("select other_id from m_quest_link where quest_id=? and kind='pre_any'", qid)]
    pa = [o for o in pa if o not in pre]
    return {"id": qid, "name": name, "level": level, "min": minl, "races": int(races or 0),
            "classes": int(classes or 0), "text": " ".join((otext or "").split()), "pre": pre, "pa": pa}


def quest_who(q):
    """Who a quest is for, from its race and class masks. A class quest is for that class of
    either race (the data gives some Skyborne class quests a faction they do not have)."""
    def ok(v):
        if q["classes"]:
            return bool(q["classes"] & CLASS_BITS.get(v["class"], 0))
        mask = q["races"]
        if not mask:
            return True
        # The Skyborne races are bits 32 (High Order) and 33 (Windshaper); a classic mask with
        # every race of a faction (77 Alliance, 178 Horde) is for its Skyborne race too.
        if v["race"] == 95:
            return bool(mask & (1 << 32)) or mask & 77 == 77
        if v["race"] == 96:
            return bool(mask & (1 << 33)) or mask & 178 == 178
        return bool(mask & (1 << (v["race"] - 1)))
    return ok


def relation(qid, role):
    """The entity giving (start) or taking (end) a quest: (kind, id), the one in the zone first."""
    rs = rows("select entity_type, entity_id from m_quest_relation where quest_id=? and role=?", qid, role)
    rs.sort(key=lambda r: 0 if r[0] != "item" and spawns(r[0], r[1], area) else 1)
    return rs[0] if rs else (None, None)


def emit(step, n, opts, filt):
    step["_line"] = n
    step["_who"] = filt
    if opts.get("at"):
        step["m"] = opts.get("in") or current_map
        step["x"], step["y"] = opts["at"]
    if opts.get("bg"):
        step["bg"] = True
    if opts.get("icon"):
        # Not a kill: no mobs for the target buttons.
        step["ic"] = opts["icon"]
        if opts["icon"] != "kill" and opts.get("mobs") is None:
            step.pop("mobs", None)
            step.pop("mi", None)
        if opts["icon"] == "talk" and step.get("n") and step["k"] not in ("note", "goto"):
            step["t"] = f"Talk to {step['n']}"
    if opts.get("nopre"):
        step.pop("pre", None)
        step.pop("pa", None)
    if opts.get("t"):
        step["t"] = opts["t"]
    steps.append(step)
    return step


def place(step, where):
    if where and "m" not in step:
        step["m"], step["x"], step["y"] = where


for n, text in lines:
    word, _, rest = text.partition(" ")
    word = word.lower()
    if word == "guide":
        guide["name"] = rest.strip(); continue
    if word == "map":
        current_map = uimap.get(rest.strip()) or fail(n, "unknown map " + rest)
        area = area_of_map(rest.strip()) or fail(n, "no area named " + rest)
        area_map.setdefault(area, current_map)
        continue
    if word == "races":
        guide["races"] = [int(w) for w in rest.split()]; continue
    if word == "faction":
        f = rest.strip().capitalize()
        guide["races"] = sorted(r for r, fa in race_faction.items() if fa == f and r in race_classes)
        continue
    if word == "next":
        guide["next"] = rest.strip(); continue
    if word in ("carry", "leave"):
        (carried if word == "carry" else left).update(int(w) for w in rest.split())
        continue
    if word == "levels":
        a, b = rest.split()
        guide["from"], guide["to"] = int(a), int(b); continue

    # Free text: the quoted or remaining text, then the options.
    if word in ("note", "tip", "goto"):
        m = re.match(r'^"([^"]*)"\s*(.*)$', rest)
        if word == "tip":
            # A tip is its whole line.
            steps[-1].setdefault("nt", []).append({"l": 2, "t": m.group(1) if m else rest.strip()})
            continue
        if m:
            said, optwords = m.group(1), m.group(2).split()
        else:
            # The text runs up to the first word from which the rest reads as options ("Wait in
            # the hut at 40,50" -> "Wait in the hut", at 40,50).
            words_t = rest.split()
            said, optwords = rest.strip(), []
            for k in range(1, len(words_t)):
                if words_t[k] in OPTION_WORDS and opts_ok(words_t[k:]):
                    said, optwords = " ".join(words_t[:k]), words_t[k:]
                    break
        opts = parse_opts(n, optwords)
        filt = who(opts["only"])
        if word == "tip":
            prev = steps[-1]
            prev.setdefault("nt", []).append({"l": 2, "t": said})
            continue
        step = {"k": word, "t": said}
        if word == "goto":
            if not opts.get("at"):
                fail(n, "goto needs at x,y")
            step["r"] = opts.get("r", 15)
        if opts.get("npc"):
            step["e"], step["id"], step["n"] = "npc", opts["npc"], name_of("npc", opts["npc"])
            place(step, None)
            emit(step, n, opts, filt)
            place(step, place_of("npc", opts["npc"], area))
            continue
        emit(step, n, opts, filt)
        continue

    if word == "fly":
        # fly <node name> npc <flight master>: the node's name up to the options.
        m = re.match(r'^"([^"]+)"\s*(.*)$', rest) or re.match(r"^(.+?)\s+(npc\s.*|at\s.*|only\s.*)$", rest)
        if not m:
            fail(n, "fly <node name> npc <flight master>")
        node_name, optwords = m.group(1).strip(), m.group(2).split()
        opts = parse_opts(n, optwords)
        # Several nodes share a name (one per faction): the one of the guide's faction (its mount).
        nodes = rows("select ID, Name_lang, MountCreatureID_0, MountCreatureID_1 from client_taxinodes where Name_lang=?",
                     node_name) or rows("""select ID, Name_lang, MountCreatureID_0, MountCreatureID_1 from client_taxinodes
                                           where Name_lang like ? order by ID""", node_name + "%")
        if not nodes:
            fail(n, "no flight node named " + node_name)
        factions = {race_faction[r] for r in guide["races"]}
        def serves(nd):
            return ("Horde" in factions and nd[2]) or ("Alliance" in factions and nd[3])
        node = next((nd for nd in nodes if serves(nd)), nodes[0])
        short = node[1].split(",")[0]
        step = {"k": "fly", "t": f"Fly to {short}", "e": "taxi", "id": int(node[0]), "n": short}
        emit(step, n, opts, who(opts["only"]))
        if opts.get("npc"):
            place(step, place_of("npc", opts["npc"], area))
        if "m" not in step:
            fail(n, "fly needs the flight master (npc <id>) or at x,y")
        continue

    words = shlex.split(rest)
    ids = []
    while words and re.match(r"^\d+(\.\d+)?$", words[0]):
        ids.append(words.pop(0))
    opts = parse_opts(n, words)
    filt = who(opts["only"])

    if word in ("accept", "turnin"):
        for qs in ids:
            q = quest(int(qs), n)
            kind, eid = relation(q["id"], "start" if word == "accept" else "end")
            if opts.get("npc"):
                kind, eid = "npc", opts["npc"]
            qf = quest_who(q)
            step = {"k": word, "q": q["id"]}
            if kind == "item":
                step["t"] = f"Accept {q['name']} from {name_of('item', eid)}"
                step["e"], step["id"], step["n"] = "item", eid, name_of("item", eid)
            elif kind:
                who_name = name_of(kind, eid)
                step["t"] = (f"Accept {q['name']} from {who_name}" if word == "accept"
                             else f"Turn in {q['name']} to {who_name}")
                step["e"], step["id"], step["n"] = kind, eid, who_name
                if kind == "object":
                    step["ic"] = "object"
            if word == "accept":
                step["min"] = q["min"] or 1
                if q["pre"]:
                    step["pre"] = q["pre"]
                if q["pa"]:
                    step["pa"] = q["pa"]
                # A profession's quest: only with that profession.
                m = re.match(r"^Camping 101: (.+)$", q["name"])
                if m and m.group(1) in PROFESSION_LINES:
                    step["line"], step["sk"] = PROFESSION_LINES[m.group(1)], 1
            emit(step, n, opts, lambda v, a=filt, b=qf: a(v) and b(v))
            if kind in ("npc", "object"):
                place(step, place_of(kind, eid, area))
            if "m" not in step and len(steps) > 1:
                # Started by an item (looted on the step before) or by no one known: where the step
                # before is.
                prev = next((p for p in reversed(steps[:-1]) if p.get("m")), None)
                if prev:
                    step["m"], step["x"], step["y"] = prev["m"], prev["x"], prev["y"]
            step["_q"] = q
        continue

    if word == "do":
        for qs in ids:
            qid, _, only_o = qs.partition(".")
            q = quest(int(qid), n)
            qf = quest_who(q)
            objs = rows("select idx, type, target_id, amount, text from m_quest_objective where quest_id=? order by idx", q["id"])
            if only_o:
                objs = [o for o in objs if o[0] == int(only_o)]
            if not objs:
                # No objective in the data: the quest's text, at the place given.
                if not opts.get("at"):
                    fail(n, f"quest {qid}: no objective in the data, give its place with at x,y")
                step = {"k": "objective", "q": q["id"], "o": int(only_o or 1), "t": q["text"] or q["name"], "ic": "text"}
                if opts.get("mobs") is not None:
                    step["ic"] = "kill"
                    step["mobs"] = [name_of("npc", i) for i in opts["mobs"]]
                    step["mi"] = list(opts["mobs"])
                emit(step, n, opts, lambda v, a=filt, b=qf: a(v) and b(v))
                step["_q"] = q
                continue
            for idx, typ, target, amount, otext in objs:
                step = {"k": "objective", "q": q["id"], "o": int(idx)}
                amount = int(amount) if amount else None
                spots = []
                if typ in ("creature", "killcredit", "talk"):
                    nm = name_of("npc", target)
                    step["n"], step["e"], step["id"] = nm, "npc", target
                    # Without a count (and no mobs given): someone to speak with.
                    if typ == "talk" or (typ == "creature" and amount is None and opts.get("mobs") is None):
                        step["ic"], step["t"] = "talk", f"Talk to {nm}"
                    else:
                        step["ic"] = "kill"
                        step["t"] = f"Kill {nm}" + (f" x{amount}" if amount and amount > 1 else "")
                        step["mobs"], step["mi"] = [nm], [target]
                    spots = groups(spawns("npc", target, area))
                elif typ == "object":
                    nm = name_of("object", target)
                    step["n"], step["e"], step["id"], step["ic"] = nm, "object", target, "use"
                    step["t"] = f"Use {nm}" + (f" x{amount}" if amount and amount > 1 else "")
                    spots = groups(spawns("object", target, area))
                elif typ == "item":
                    nm = name_of("item", target)
                    step["n"], step["e"], step["id"], step["ic"] = nm, "item", target, "get"
                    step["c"] = amount or 1
                    step["t"] = nm + (f" x{amount}" if amount and amount > 1 else "")
                    ia = area
                    src = rows("""select from_type, from_id, chance from m_item_source i where item_id=?
                                  and from_type in ('npc','object') and exists (select 1 from m_spawn s
                                  where s.entity_type=i.from_type and s.entity_id=i.from_id and s.zone_id=?)""",
                               target, area)
                    if not src:
                        # None here: the sources elsewhere, in the area most of them are.
                        allsrc = rows("""select from_type, from_id, chance from m_item_source where item_id=?
                                         and from_type in ('npc','object')""", target)
                        counts = {}
                        for ft, fid, _ in allsrc:
                            a2 = best_area(ft, fid)
                            if a2:
                                counts[a2] = counts.get(a2, 0) + 1
                        if counts:
                            other = max(counts, key=counts.get)
                            src = [s3 for s3 in allsrc if spawns(s3[0], s3[1], other)]
                            ia = other
                    # Sources ranked by how many spawn here, then their drop chance.
                    src = sorted(src, key=lambda s: (-len(spawns(s[0], s[1], ia)), -(float(s[2] or 0))))
                    mobs = [s for s in src if s[0] == "npc"][:4]
                    objects = [s for s in src if s[0] == "object"]
                    if mobs and (not objects or len(spawns("npc", mobs[0][1], ia)) >= len(spawns("object", objects[0][1], ia))):
                        step["ic"] = "get"
                        step["mobs"] = [name_of("npc", s[1]) for s in mobs]
                        step["mi"] = [s[1] for s in mobs]
                        spots = groups(spawns("npc", mobs[0][1], ia))
                    elif objects:
                        step["ic"] = "pickup"
                        step["nt"] = [{"l": 1, "t": f"Loot them from {name_of('object', objects[0][1])}."}]
                        spots = groups(sum((spawns("object", s[1], ia) for s in objects), []))
                else:
                    step["ic"], step["t"] = "text", otext or q["text"] or q["name"]
                spots_area = ia if typ == "item" else area
                if typ in ("creature", "killcredit", "talk", "object") and not spots:
                    # Not in this zone: where it is.
                    a2 = best_area("npc" if typ != "object" else "object", target)
                    if a2:
                        spots_area, spots = a2, groups(spawns("npc" if typ != "object" else "object", target, a2))
                if opts.get("mobs") is not None:
                    step["mobs"] = [name_of("npc", i) for i in opts["mobs"]]
                    step["mi"] = list(opts["mobs"])
                    # Where the mobs given are.
                    here = groups(spawns("npc", opts["mobs"][0], area))
                    if here:
                        spots, spots_area = here, area
                    if not here and best_area("npc", opts["mobs"][0]):
                        spots_area = best_area("npc", opts["mobs"][0])
                        spots = groups(spawns("npc", opts["mobs"][0], spots_area))
                emit(step, n, opts, lambda v, a=filt, b=qf: a(v) and b(v))
                if spots:
                    place(step, (area_map[spots_area], spots[0][0], spots[0][1]))
                    extra = [{"m": area_map[spots_area], "x": x, "y": y} for x, y, c in spots[1:4] if c >= 3]
                    if extra:
                        step["spots"] = extra
                if "m" not in step:
                    fail(n, f"quest {qid} objective {idx}: no place in the data, give it with at x,y")
                step["_q"] = q
        continue

    if word == "train":
        for s in ids:
            npc = int(s)
            nm = name_of("npc", npc)
            sub = (one("select subname from m_npc where id=?", npc) or [""])[0] or ""
            m = re.match(r"^(\w+) Trainer$", sub)
            cls = CLASS_IDS.get(m.group(1).lower()) if m else None
            if not cls:
                fail(n, f"{nm} ({sub}) is not a class trainer")
            step = {"k": "train", "t": f"Train with {nm}", "e": "npc", "id": npc, "n": nm}
            emit(step, n, opts, lambda v, a=filt, c=cls: a(v) and v["class"] == c)
            place(step, place_of("npc", npc, area))
        continue

    if word in ("sell", "bind"):
        npc = int(ids[0])
        nm = name_of("npc", npc)
        t = f"Sell your loot to {nm}" if word == "sell" else f"Set your hearthstone with {nm}"
        step = {"k": word, "t": t, "e": "npc", "id": npc, "n": nm}
        emit(step, n, opts, filt)
        place(step, place_of("npc", npc, area))
        continue

    if word == "ah":
        if not ids or "." not in ids[0] or not opts.get("npc"):
            fail(n, "ah <quest>.<objective> npc <auctioneer>")
        qid, _, oi = ids[0].partition(".")
        q = quest(int(qid), n)
        o = one("select target_id, amount from m_quest_objective where quest_id=? and idx=? and type='item'", q["id"], int(oi))
        if not o:
            fail(n, f"quest {qid} has no item objective {oi}")
        item, amount = int(o[0]), int(o[1] or 1)
        nm = name_of("item", item)
        step = {"k": "objective", "q": q["id"], "o": int(oi), "ic": "buy", "n": nm, "e": "item", "id": item,
                "c": amount, "by": True, "bg": True,
                "t": f"Buy {amount} {nm} at the auction house (optional)"}
        # The best single drop chance (some sources give a percent, not a fraction).
        chances = [float(c) for (c,) in rows("""select chance from m_item_source where item_id=? and
                   from_type in ('npc','object') and chance is not null""", item)]
        chances = [c / 100 if c > 1 else c for c in chances]
        best = max(chances, default=0)
        if rows("select 1 from m_item_source where item_id=? and from_type='vendor'", item):
            said = f"For {q['name']}: a vendor sells them too. Buy them here, or at the vendor, or farm them."
        elif not rows("select 1 from m_item_source where item_id=? and from_type in ('npc','object')", item):
            said = f"For {q['name']}: nothing drops them, they are made by a craft. Buy them, or have a crafter make them."
        elif best and best < 0.3:
            said = f"For {q['name']}: they drop only {best:.0%} of the time. Skip it to farm them instead."
        else:
            said = f"For {q['name']}: buying them saves the farming. Skip it to farm them instead."
        step["nt"] = [{"l": 1, "t": said}]
        emit(step, n, opts, lambda v, a=filt, b=quest_who(q): a(v) and b(v))
        place(step, place_of("npc", opts["npc"], area))
        step["_q"] = q
        step["_ah"] = True
        continue

    if word == "fpath":
        npc = int(ids[0])
        nm = name_of("npc", npc)
        step = {"k": "flight_master", "t": f"Get the flight path from {nm}", "e": "npc", "id": npc, "n": nm}
        emit(step, n, opts, filt)
        place(step, place_of("npc", npc, area))
        continue

    if word == "hearth":
        if not opts.get("npc") and not opts.get("at"):
            fail(n, "hearth needs the innkeeper (npc <id>) or at x,y")
        step = {"k": "hearth", "t": "Use your hearthstone"}
        if opts.get("npc"):
            where = place_of("npc", opts["npc"], area)
            sub_area = one("select zone_id from m_spawn where entity_type='npc' and entity_id=?", opts["npc"])
            step["t"] = f"Use your hearthstone to {name_of('npc', opts['npc'])}"
        emit(step, n, opts, filt)
        if opts.get("npc"):
            place(step, where)
        continue

    if word == "grind":
        lvl = int(ids[0])
        step = {"k": "grind", "t": f"Kill enemies here until level {lvl}", "lvl": lvl}
        emit(step, n, opts, filt)
        continue

    fail(n, "unknown line: " + word)

if not guide["name"] or not guide["races"] or current_map is None:
    sys.exit("the script needs guide, races and map lines")

# Variants, and the steps each is in.
variants = variants_all()
for s in steps:
    inside = [i + 1 for i, v in enumerate(variants) if s["_who"](v)]
    if not inside:
        sys.exit(f"{args.script}:{s['_line']}: a step for no character ({s.get('t')})")
    s["_in"] = inside
    if len(inside) < len(variants):
        s["only"] = inside

# Levels: each character's XP along the route (the quests handed in, the mobs their objectives
# kill, as the app counts them), the step at the lowest level any character reaches it.
XP_TO_NEXT = [  # crates/fg-route/src/xp.rs CLASSIC_XP: from level l to l + 1 (index 0 = level 1)
    400, 900, 1400, 2100, 2800, 3600, 4500, 5400, 6500, 7600, 8800, 10100, 11400, 12900, 14400, 16000, 17700, 19400,
    21300, 23200, 25200, 27300, 29400, 31700, 34000, 36400, 38900, 41400, 44300, 47400, 50800, 54500, 58600, 62800,
    67100, 71600, 76100, 80800, 85700, 90700, 95800, 101000, 106300, 111800, 117500, 123200, 129100, 135100, 141200,
    147500, 153900, 160400, 167100, 173900, 180800, 187900, 195000, 202300, 209800,
]


def mob_xp(level, mob):
    base = lambda l: l * 5 + 45
    if mob >= level:
        return base(level) * (1 + 0.05 * min(mob - level, 4))
    gray = level - 5 if level <= 5 else level - 1 - level // 10 - 4 if level < 40 else level - 1 - level // 5
    if mob <= gray:
        return 0
    zd = (5 if level < 8 else 6 if level < 10 else 7 if level < 12 else 8 if level < 16 else 9 if level < 20
          else 11 if level < 30 else 12 if level < 40 else 13 if level < 45 else 14 if level < 50 else 15 if level < 55
          else 16 if level < 60 else 17)
    return base(mob) * (1 - (level - mob) / zd)


def mob_level(npc):
    r = one("select min_level, max_level from m_npc where id=?", npc)
    return ((r[0] or 1) + (r[1] or r[0] or 1)) / 2 if r else 1


for vi in range(1, len(variants) + 1):
    level, xp = guide["from"], 0
    for s in steps:
        if vi not in s["_in"]:
            continue
        s["_lvl"] = min(s.get("_lvl", 99), level)
        gain = 0
        if s["k"] == "turnin":
            gain = int(one("select coalesce(xp, 0) from m_quest where id=?", s["q"])[0] or 0)
        elif s["k"] == "objective" and s.get("mi"):
            kills = (s.get("c") or 1) * (1.6 if s.get("e") == "item" else 1)
            if s["ic"] == "kill" and s.get("e") == "npc":
                kills = int(one("select coalesce(amount, 1) from m_quest_objective where quest_id=? and idx=?",
                                s["q"], s["o"])[0] or 1)
            gain = kills * mob_xp(level, mob_level(s["mi"][0]))
        elif s["k"] == "grind":
            while level < s["lvl"]:
                xp, level = 0, level + 1
        xp += gain
        while level <= len(XP_TO_NEXT) and xp >= XP_TO_NEXT[level - 1]:
            xp -= XP_TO_NEXT[level - 1]
            level += 1
    print(f"  {variants[vi - 1]}: level {level} and {int(xp)} XP at the end")
for s in steps:
    if s["k"] != "grind":
        s["lvl"] = min(s.get("_lvl", guide["from"]), guide["to"])

# Every variant's quests: each one handed in is taken before (or carried from the guide before),
# after its objectives; each one taken is handed in (or left to the next guide).
errors = []
# A carried quest is for the characters who can have it (a class quest for its class).
carried_who = {q: quest_who(quest(q, 0)) for q in carried}


def carried_for(v):
    return {q for q in carried if carried_who[q](v)}


for vi in range(1, len(variants) + 1):
    v = variants[vi - 1]
    who_v = f"race {v['race']} class {v['class']}"
    taken, handed = carried_for(v), {}
    mine = [s for s in steps if vi in s["_in"]]
    for s in mine:
        if s["k"] == "accept":
            taken.add(s["q"])
        elif s["k"] in ("turnin", "objective") and s["q"] not in taken and not s.get("_ah"):
            errors.append(f"{args.script}:{s['_line']}: quest {s['q']} is not taken before ({who_v})")
        if s["k"] == "turnin":
            handed[s["q"]] = s["_line"]
        elif s["k"] == "objective" and s["q"] in handed:
            errors.append(f"{args.script}:{s['_line']}: quest {s['q']} has an objective after its turn-in "
                          f"(line {handed[s['q']]}, {who_v})")
    for q in sorted(taken - set(handed) - left):
        line = next((s["_line"] for s in mine if s.get("q") == q), 0)
        errors.append(f"{args.script}:{line}: quest {q} is taken and never handed in ({who_v}): hand it in, "
                      f"or 'leave' it to the next guide when it is a breadcrumb there")
# The quest log holds 40 quests (WoW Forever): count each character's along the route, the quests
# carried in included; a profession's optional quests are left out.
LOG_MAX, LOG_WARN = 40, 36
log_peak = 0
for vi in range(1, len(variants) + 1):
    log = carried_for(variants[vi - 1])
    worst, worst_line = len(log), 0
    for s in steps:
        if vi not in s["_in"]:
            continue
        if s["k"] == "accept" and not s.get("line"):
            log.add(s["q"])
        elif s["k"] == "turnin":
            log.discard(s["q"])
        if len(log) > worst:
            worst, worst_line = len(log), s["_line"]
    log_peak = max(log_peak, worst)
    v = variants[vi - 1]
    if worst > LOG_MAX:
        errors.append(f"{args.script}:{worst_line}: {worst} quests in the log here (race {v['race']} class "
                      f"{v['class']}): the log holds {LOG_MAX}")
    elif worst > LOG_WARN:
        warn(worst_line, f"{worst} quests in the log here (race {v['race']} class {v['class']}): close to {LOG_MAX}")
if errors:
    # The same mistake for many characters: once.
    seen = []
    for e in errors:
        key = e.split(" (")[0]
        if key not in seen:
            seen.append(key)
            print(e, file=sys.stderr)
    sys.exit(f"{len(seen)} error(s)")


# Warnings: a quest taken at a giver met before in the guide, while it could already be taken (the
# quests of a hub are taken at once); a quest taken whose objectives no step does.
def near(a, b, d=2.5):
    return a.get("m") and b.get("m") and a["m"] == b["m"] and math.hypot(a["x"] - b["x"], a["y"] - b["y"]) < d


done_at = {}
for i, s in enumerate(steps):
    if s["k"] == "turnin":
        done_at.setdefault(s["q"], i)
quests_in = {s["q"] for s in steps if s.get("q")}
for i, s in enumerate(steps):
    if s["k"] != "accept" or not s.get("e") in ("npc", "object"):
        continue
    q = s["_q"]
    for j in range(i):
        e = steps[j]
        same = (e.get("e") == s["e"] and e.get("id") == s["id"]) or (e["k"] != "objective" and near(e, s, 0.6))
        # A step only some characters play (a profession's quest) is no visit.
        if not same or not set(e["_in"]) & set(s["_in"]) or e.get("line") or (e["k"] == "turnin" and e["_q"]["name"].startswith("Camping 101")):
            continue
        # Could it be taken then: its prerequisites done (those of this guide handed in before),
        # the planned level reached.
        ok = all(p not in quests_in or done_at.get(p, 1e9) < j for p in q["pre"])
        if q["pa"] and any(p in quests_in for p in q["pa"]):
            ok = ok and any(done_at.get(p, 1e9) < j for p in q["pa"])
        ok = ok and (e.get("lvl") or 0) >= (q["min"] or 1)
        # Left the giver in between (not the same visit).
        away = any(not near(steps[k], s, 3) for k in range(j + 1, i) if steps[k].get("m"))
        if ok and away:
            warn(s["_line"], f"{q['name']} ({q['id']}) could be taken at line {e['_line']}, at the same giver")
        break
for qid in sorted({s["q"] for s in steps if s["k"] == "accept"} - left):
    # Objectives other than speaking to whoever takes the quest (done at its turn-in).
    enders = {e for (e,) in rows("select entity_id from m_quest_relation where quest_id=? and role='end'", qid)}
    has_obj = [t for (t, typ, amt) in rows("select target_id, type, amount from m_quest_objective where quest_id=?", qid)
               if not (t in enders and (typ == "talk" or not amt or amt == 1))]
    if has_obj and not any(s["k"] == "objective" and s["q"] == qid for s in steps):
        line = next(s["_line"] for s in steps if s.get("q") == qid)
        warn(line, f"quest {qid} has objectives but no 'do' step")
# A quest planned before the character can take it (its minimum level): a grind first.
for s in steps:
    if s["k"] == "accept" and s.get("min") and s.get("lvl") and s["lvl"] < s["min"] and not s.get("line"):
        warn(s["_line"], f"{s['_q']['name']} ({s['q']}) needs level {s['min']}, planned at {s['lvl']}: add a grind "
             f"before it, or take it later")
for w in WARNINGS:
    print(w, file=sys.stderr)


# Output ------------------------------------------------------------------------------------------

def lua(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int,)):
        return str(v)
    if isinstance(v, float):
        return ("%.2f" % v).rstrip("0").rstrip(".")
    if isinstance(v, str):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
    if isinstance(v, list):
        return "{ " + ", ".join(lua(x) for x in v) + " }"
    if isinstance(v, dict):
        return "{ " + ", ".join(f"{k} = {lua(x)}" for k, x in v.items()) + " }"
    raise TypeError(v)


ORDER = ["k", "t", "q", "o", "ic", "n", "e", "id", "c", "by", "m", "x", "y", "r", "spots", "mobs", "mi", "min",
         "pre", "pa", "line", "sk", "bg", "nt", "lvl", "only"]
slug = re.sub(r"[^A-Za-z0-9]", "", guide["name"])
path = os.path.join(args.out, slug + ".lua")
src = os.path.relpath(args.script)
with open(path, "w", encoding="utf-8") as out:
    out.write(f"-- Built by addon/tools/guide_build.py from {src} and the game data. Do not edit:\n")
    out.write("-- change the script and build again.\n")
    out.write("Pathwright.Builtin.Register({\n")
    out.write(f"    name = {lua(guide['name'])},\n")
    out.write(f"    origin = {lua('Pathwright: ' + src)},\n")
    out.write(f"    fromLevel = {guide['from']},\n    toLevel = {guide['to']},\n")
    out.write('    locale = "enUS",\n    version = 1,\n    format = 2,\n')
    out.write(f"    created = {int(os.path.getmtime(args.script))},\n")
    if guide["next"]:
        out.write(f"    next = {lua(guide['next'])},\n")
    if carried:
        # Taken in the guide before: handed in here without being taken.
        out.write(f"    carry = {lua(sorted(carried))},\n")
    out.write("    variants = {\n")
    for v in variants:
        out.write(f"        {lua(v)},\n")
    out.write("    },\n    steps = {\n")
    for s in steps:
        clean = {k: s[k] for k in ORDER if k in s}
        out.write(f"        {lua(clean)},\n")
    out.write("    },\n})\n")

counts = {}
for s in steps:
    counts[s["k"]] = counts.get(s["k"], 0) + 1
quests = {s["q"] for s in steps if s.get("q")}
print(f"{guide['name']}: {len(WARNINGS)} warning(s), log at most {log_peak}, {len(steps)} steps ({', '.join(f'{k} {c}' for k, c in sorted(counts.items()))}), "
      f"{len(quests)} quests, {len(variants)} variants -> {path}")
if tmp:
    os.unlink(tmp.name)
