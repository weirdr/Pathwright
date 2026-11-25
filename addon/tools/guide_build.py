#!/usr/bin/env python3
"""Build a built-in Pathwright guide from an authored guide script and the game data.

    python3 addon/tools/guide_build.py addon/guides/skyborne_starter.guide \
        [--db data/forever.sqlite.zst] [--out addon/Pathwright_Guide/Builtin] [--fg target/release/fg]
        [--no-walks]

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
    next <guide name>             the guide that follows (the addon opens it when this one ends);
    next horde|alliance <name>    the one that follows for that faction (a guide both factions play)
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
    note <text>                   something to do by hand (marked done; with "have", done once
                                  the item is in the bags)
    goto <text>                   a place to reach (needs "at")
    grind <level>                 kill on the way until that level
    tip <text>                    a tip on the step before (the whole line)
    path                          the walking path of the NPC of the step before (the data's
                                  m_npc_path), drawn on the world map while the step is current
    route off / route on          keep the visits that follow in the script's order (see below)

Options after a step, in any order:

    at <x>,<y>      the place (else the data's: the NPC, the main group of its mobs)
    in <uiMap>      the map of "at" for this step only
    mobs <npc>...   the mobs of an objective (else the data's); makes a count-less one a kill
    r <yards>       how close a "goto" is reached
    bg              an objective done along the way, while doing the steps after it
    icon <icon>     the step's icon (talk, use, kill, get, pickup, text...); not kill: no mobs
    nopre           take no prerequisite from the data (when it is wrong)
    after <quest>.. its real prerequisites, in place of the data's (when they are wrong)
    late            an accept taken on purpose at a later visit to its giver (no warning)
    skill <prof> [n] an accept offered only to characters with that profession (First_Aid for two
                    words) at rank n (1 if left out): skipped, with its other steps, without it
    only <who>...   alliance, horde, class names (warrior, mage...) and race names (orc, undead,
                    tauren, troll, windshaper...): who the step is for ("only priest troll")
    have <item> [quest]
                    a note's item: the note is done once the bags hold it (a kill and loot), or
                    once the quest the item starts is in the log or turned in
    npc <npc>       the NPC of a note, or who takes a quest handed in (its name and place)
    "<text>"        the step's text (tip, note and goto take the rest of the line)

Routing: a run of visits in one place (accepts, turn-ins, trainers, vendors, the innkeeper, the
flight master, all within HUB_SPAN map units of each other) is walked in the shortest order, from
where the step before leaves the player to where the step after takes them. Each NPC's steps stay
together and in the script's order, and a quest is never taken before one it needs (handed in in
the same run) nor handed in before it is taken. `route off` keeps the script's order instead.

Checks: the build stops on a quest taken and never handed in (unless left to the next guide), a
quest handed in without being taken or before its objectives are done, a quest log over 40 (the
game's limit, the quests carried in counted; over 36 warns), and warns of a quest taken
at a giver met earlier in the guide while it could already be taken there (take everything a hub
gives at once), and of a quest taken whose objectives no step does.

Walks: each step gets the walk to it (`wp`: where it starts, then where it turns around the steep
ground, world coordinates), as the app's guides do, for the addon's compass and path lines. The
walk starts where the step before leaves the character: its place; where the flight of a `fly`
lands; the inn of a `hearth` (no walk to it: the hearthstone takes the character there), and so
does a `goto` that says it is reached by flight, zeppelin or boat; nowhere after a `note` that
says to take a flight, zeppelin, boat or teleport. Steps done along the way (`bg`) neither get a
walk nor move its start; a step without a place keeps it. The step before may differ between the
variants (`only`): a step whose walk does is given the most common one (`wp`) and the others
(`wv = { { { variant index, ... }, { x1, y1, ... } }, ... }`, an empty walk for none), which
Builtin.Expand resolves. The walks are worked out by the app's planner, once per faction:
`fg --db <db> guide-walks -` (`--fg <binary>` or $FG_BIN, else `cargo run --release -p fg`);
`--no-walks` leaves them out (quicker, while writing the script). scripts/build-builtin-guides.sh
rebuilds every guide with them.
"""
import argparse, atexit, json, math, os, re, shlex, sqlite3, subprocess, sys, tempfile, time

ap = argparse.ArgumentParser()
ap.add_argument("script")
ap.add_argument("--db", default="data/forever.sqlite.zst")
ap.add_argument("--out", default="addon/Pathwright_Guide/Builtin")
ap.add_argument("--fg", default=os.environ.get("FG_BIN"),
                help="the fg binary that works out the walks (default: $FG_BIN, else cargo run --release -p fg)")
ap.add_argument("--no-walks", action="store_true", help="leave the walks out (quicker, to try a script)")
args = ap.parse_args()
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# The game data (zstd compressed in the repository).
if args.db.endswith(".zst"):
    tmp = tempfile.NamedTemporaryFile(suffix=".sqlite", delete=False)
    tmp.close()
    # Removed at the end, also when the build stops.
    atexit.register(os.unlink, tmp.name)
    subprocess.run(["zstd", "-dqf", args.db, "-o", tmp.name], check=True)
    dbpath = tmp.name
else:
    dbpath, tmp = args.db, None
db = sqlite3.connect(dbpath)
one = lambda sql, *a: db.execute(sql, a).fetchone()
rows = lambda sql, *a: db.execute(sql, a).fetchall()

CLASS_BITS = {1: 1, 2: 2, 3: 4, 4: 8, 5: 16, 7: 64, 8: 128, 9: 256, 11: 1024}
# Race names for "only" (a race-only step: Shadowguard for Troll priests...).
RACE_IDS = {"human": 1, "orc": 2, "dwarf": 3, "nightelf": 4, "undead": 5, "tauren": 6, "gnome": 7,
            "troll": 8, "highorder": 95, "windshaper": 96}
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
        elif w == "late":
            o["late"] = True; i += 1
        elif w == "skill":
            prof = words[i + 1].replace("_", " ") if i + 1 < len(words) else ""
            if prof not in PROFESSION_LINES:
                fail(n, "skill <" + "|".join(sorted(PROFESSION_LINES)) + "> [rank]")
            i += 2
            rank = 1
            if i < len(words) and words[i].isdigit():
                rank = int(words[i]); i += 1
            o["skill"] = (PROFESSION_LINES[prof], rank)
        elif w == "after":
            o["after"] = []
            i += 1
            while i < len(words) and words[i].isdigit():
                o["after"].append(int(words[i])); i += 1
            if not o["after"]:
                fail(n, "after <quest>...")
        elif w == "icon":
            o["icon"] = words[i + 1]; i += 2
        elif w == "npc":
            if not words[i + 1].isdigit():
                fail(n, "npc <id>")
            o["npc"] = int(words[i + 1]); i += 2
        elif w == "have":
            if i + 1 >= len(words) or not words[i + 1].isdigit():
                fail(n, "have <item id> [quest id]")
            o["have"] = int(words[i + 1]); i += 2
            # The quest the item starts: the note stays done once the item is used up.
            if i < len(words) and words[i].isdigit():
                o["havequest"] = int(words[i]); i += 1
        elif w == "mobs":
            o["mobs"] = []
            i += 1
            while i < len(words) and words[i].isdigit():
                o["mobs"].append(int(words[i])); i += 1
        elif w == "only":
            i += 1
            start = i
            while i < len(words) and words[i].lower() in ("alliance", "horde", *CLASS_IDS, *RACE_IDS):
                o["only"].append(words[i].lower()); i += 1
            if i == start:
                fail(n, "only <faction, class or race>")
        elif " " in w and not quiet:
            o["t"] = w; i += 1
        else:
            fail(n, "unknown option " + w)
    return o


OPTION_WORDS = {"at", "in", "r", "bg", "nopre", "late", "skill", "after", "icon", "npc", "mobs", "only", "have"}


def opts_ok(words):
    """Whether these words read as options."""
    try:
        parse_opts(0, words, quiet=True)
        return True
    except ValueError:
        return False


def who(only_words):
    """The variant filter of "only" words: factions, classes and races (a list of one kind is any
    of them; the kinds combine: "only priest troll" is Troll priests)."""
    factions = {w.capitalize() for w in only_words if w in ("alliance", "horde")}
    classes = {CLASS_IDS[w] for w in only_words if w in CLASS_IDS}
    races = {RACE_IDS[w] for w in only_words if w in RACE_IDS}
    return lambda v: ((not factions or v["faction"] in factions) and (not classes or v["class"] in classes)
                      and (not races or v["race"] in races))


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
        mask = q["races"]
        if q["classes"]:
            if not q["classes"] & CLASS_BITS.get(v["class"], 0):
                return False
            # A race-only class quest (Shadowguard for Troll priests): its classic race mask holds,
            # unless it names a whole faction. Skyborne characters go by the class alone.
            if mask and v["race"] < 32 and mask < (1 << 32) and mask & 178 != 178 and mask & 77 != 77:
                return bool(mask & (1 << (v["race"] - 1)))
            return True
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


route_on = True  # `route off` keeps the script's order of the visits that follow


def emit(step, n, opts, filt):
    step["_line"] = n
    step["_who"] = filt
    step["_noroute"] = not route_on
    step["_late"] = bool(opts.get("late"))
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
        # "next <guide>", or "next horde <guide>" / "next alliance <guide>" for a guide both
        # factions play (the Skyborne starter): the addon picks by the character's faction.
        m = re.match(r"^(horde|alliance)\s+(.+)$", rest.strip())
        if m:
            if not isinstance(guide["next"], dict):
                guide["next"] = {}
            guide["next"][m.group(1).capitalize()] = m.group(2).strip()
        else:
            guide["next"] = rest.strip()
        continue
    if word == "route":
        route_on = rest.strip().lower() != "off"; continue
    if word in ("carry", "leave"):
        (carried if word == "carry" else left).update(int(w) for w in rest.split())
        continue
    if word == "levels":
        a, b = rest.split()
        guide["from"], guide["to"] = int(a), int(b); continue

    if word == "path":
        prev = steps[-1]
        if prev.get("e") != "npc" or not prev.get("id"):
            fail(n, "path needs a step with an NPC before it")
        pts = []
        for z, x, y in rows("select zone_id, x, y from m_npc_path where npc_id=? order by point", prev["id"]):
            # Only the points on the map of the step (a path may cross into an unmapped zone).
            if area_map.get(int(z)) != prev["m"]:
                continue
            if not pts or abs(pts[-1][0] - x) > 0.05 or abs(pts[-1][1] - y) > 0.05:
                pts.append((x, y))
        if len(pts) < 2:
            fail(n, f"no walking path in the data for npc {prev['id']} on map {prev['m']}")
        prev["path"] = [round(v, 2) for pt in pts for v in pt]
        continue

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
        if opts.get("have") and word == "note":
            step["hv"] = opts["have"]
            if opts.get("havequest"):
                step["hq"] = opts["havequest"]
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
            if opts.get("after"):
                q = dict(q, pre=list(opts["after"]), pa=[])
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
                if opts.get("skill"):
                    step["line"], step["sk"] = opts["skill"]
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

# Routing: the visits of a hub in the shortest walk (see the top of the file). ---------------------
VISITS = {"accept", "turnin", "train", "sell", "bind", "flight_master"}
# A hub's visits are all within this many map units of its first one (a town or a camp).
HUB_SPAN = 4.0
# Up to this many NPCs, every order is tried; above, the nearest one next, then 2-opt.
EXACT_NODES = 9


def where(s):
    return (s["m"], s["x"], s["y"]) if "m" in s else None


def dist(a, b):
    if a is None or b is None or a[0] != b[0]:
        return 0.0
    return math.hypot(a[1] - b[1], a[2] - b[2])


def needs(later, earlier):
    """Whether step `later` must come after step `earlier`."""
    if later.get("q") is None or earlier.get("q") is None:
        return False
    if later["k"] == "turnin" and earlier["k"] == "accept" and later["q"] == earlier["q"]:
        return True
    if later["k"] == "accept" and earlier["k"] == "turnin":
        # Its prerequisites as written on the step (the script's `after`), else the data's.
        q = later.get("_q") or {}
        pre = later.get("pre") or q.get("pre") or []
        pa = later.get("pa") or q.get("pa") or []
        return earlier["q"] in pre or earlier["q"] in pa
    return False


def order_run(run, start, end):
    """The run's steps in the shortest valid walk from `start` to `end` (places or None)."""
    # Nodes: the NPCs (or objects, or places), each with its steps in the script's order.
    nodes, key_of = [], {}
    for s in run:
        key = (s.get("e"), s.get("id")) if s.get("id") else ("at", where(s))
        if key not in key_of:
            key_of[key] = len(nodes)
            nodes.append([])
        nodes[key_of[key]].append(s)
    if len(nodes) < 2:
        return run
    # Node b after node a when one of b's steps needs one of a's. Both ways: keep the script's order.
    after = [set() for _ in nodes]
    for b, nb in enumerate(nodes):
        for a, na in enumerate(nodes):
            if a != b and any(needs(sb, sa) for sb in nb for sa in na):
                after[b].add(a)
    for b in range(len(nodes)):
        for a in after[b]:
            if b in after[a]:
                return run
    places = [where(n[0]) for n in nodes]

    def length(order):
        total, here = 0.0, start
        for i in order:
            total += dist(here, places[i])
            here = places[i]
        return total + dist(here, end)

    def valid(order):
        seen = set()
        for i in order:
            if not after[i] <= seen:
                return False
            seen.add(i)
        return True

    # Grouping an NPC's steps may make the script's own order invalid (one of its steps comes
    # before another NPC's, the next after it): only a valid order is kept, else the script's.
    original = list(range(len(nodes)))
    best, best_len = (original, length(original)) if valid(original) else (None, math.inf)
    if len(nodes) <= EXACT_NODES:
        # Depth first over the valid orders, cut when already longer than the best.
        def walk(order, here, so_far, left):
            nonlocal best, best_len
            if so_far >= best_len - 1e-9:
                return
            if not left:
                total = so_far + dist(here, end)
                if total < best_len - 1e-9:
                    best, best_len = list(order), total
                return
            for i in sorted(left, key=lambda i: dist(here, places[i])):
                if after[i] <= set(order):
                    order.append(i)
                    walk(order, places[i], so_far + dist(here, places[i]), left - {i})
                    order.pop()
        walk([], start, 0.0, set(original))
    else:
        order, here, left = [], start, set(original)
        while left:
            ready = [i for i in left if after[i] <= set(order)]
            i = min(ready, key=lambda i: dist(here, places[i]))
            order.append(i)
            here = places[i]
            left.discard(i)
        improved = True
        while improved:
            improved = False
            for a in range(len(order) - 1):
                for b in range(a + 1, len(order)):
                    trial = order[:a] + order[a:b + 1][::-1] + order[b + 1:]
                    if valid(trial) and length(trial) < length(order) - 1e-9:
                        order, improved = trial, True
        if valid(order) and length(order) < best_len:
            best = order
    if best is None:
        return run
    return [s for i in best for s in nodes[i]]


def route_hubs(steps):
    out, i = [], 0
    while i < len(steps):
        first = steps[i]
        if first["k"] in VISITS and where(first) and not first["_noroute"]:
            j = i + 1
            while (
                j < len(steps)
                and steps[j]["k"] in VISITS
                and where(steps[j])
                and not steps[j]["_noroute"]
                and steps[j]["m"] == first["m"]
                and all(dist(where(steps[j]), where(s)) <= HUB_SPAN for s in steps[i:j])
            ):
                j += 1
            run = steps[i:j]
            if len(run) > 1:
                start = where(out[-1]) if out else None
                end = where(steps[j]) if j < len(steps) else None
                run = order_run(run, start, end)
            out.extend(run)
            i = j
        else:
            out.append(first)
            i += 1
    return out


steps = route_hubs(steps)

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
    if s["k"] != "accept" or not s.get("e") in ("npc", "object") or s.get("_late"):
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


# Walks (see the top of the file) ----------------------------------------------------------------

# A note or goto about travelling by flight, zeppelin, boat or teleport: a goto is where it lands
# (no walk to it), a note where it leaves from (no walk from it).
TRAVEL = re.compile(r"\b(fly|flights?|zeppelins?|boats?|ship|teleport|portal|hearthstone)\b", re.I)


def walk_legs(vi):
    """The walks of variant `vi`: {step index: (start, place, level)}, the places as the
    guide-walks command takes them ({m, x, y} or {taxi})."""
    legs, start = {}, None
    for i, s in enumerate(steps):
        if vi not in s["_in"] or s.get("bg"):
            continue
        here = {"m": s["m"], "x": s["x"], "y": s["y"]} if "m" in s else None
        travel = s["k"] in ("note", "goto") and TRAVEL.search(s.get("t") or "")
        arrive = s["k"] == "hearth" or (s["k"] == "goto" and travel)
        if here and start and here != start and not arrive:
            level = s["lvl"] if s["k"] != "grind" else min(s.get("_lvl", guide["from"]), guide["to"])
            legs[i] = (start, here, level)
        if s["k"] == "fly":
            start = {"taxi": s["id"]}
        elif s["k"] == "note" and travel:
            start = None
        elif here:
            start = here
    return legs


def guide_walks(faction, legs):
    """The walks of `legs` ([{from, to, level}]) for a faction, from the app's planner."""
    db_arg = ["--db", os.path.abspath(dbpath), "guide-walks", "-"]
    cmd = [os.path.abspath(args.fg)] + db_arg if args.fg else ["cargo", "run", "--release", "-q", "-p", "fg", "--"] + db_arg
    p = subprocess.run(cmd, input=json.dumps({"faction": faction, "legs": legs}), capture_output=True, text=True,
                       cwd=ROOT)
    if p.returncode != 0:
        sys.stderr.write(p.stderr)
        sys.exit(f"{args.script}: {' '.join(cmd)} failed (exit {p.returncode}); --no-walks builds without the walks")
    try:
        walks = json.loads(p.stdout)["walks"]
    except (ValueError, KeyError, TypeError):
        sys.stderr.write(p.stderr)
        sys.exit(f"{args.script}: guide-walks gave no walks: {p.stdout[:200]!r}")
    if len(walks) != len(legs):
        sys.exit(f"{args.script}: guide-walks gave {len(walks)} walks for {len(legs)} legs")
    return [tuple(int(round(c)) for c in w) for w in walks]


walk_count, leg_count = 0, 0
if not args.no_walks:
    # Every variant's legs, the same ones asked once per faction.
    per_variant = {vi: walk_legs(vi) for vi in range(1, len(variants) + 1)}
    asked = {}  # faction -> {key: index}
    for vi, legs in per_variant.items():
        keys = asked.setdefault(variants[vi - 1]["faction"].lower(), {})
        for leg in legs.values():
            keys.setdefault(json.dumps(leg, sort_keys=True), len(keys))
    found = {}
    for faction, keys in sorted(asked.items()):
        if not keys:
            continue
        legs = [json.loads(k) for k in keys]
        leg_count += len(legs)
        walks = guide_walks(faction, [{"from": a, "to": b, "level": l} for a, b, l in legs])
        for key, idx in keys.items():
            found[(faction, key)] = walks[idx]
    for i, s in enumerate(steps):
        # The variants of the step by their walk: the most common one (then the first variant's)
        # is `wp`, the others `wv`.
        by_walk = {}
        for vi in s["_in"]:
            leg = per_variant[vi].get(i)
            walk = found[(variants[vi - 1]["faction"].lower(), json.dumps(leg, sort_keys=True))] if leg else ()
            by_walk.setdefault(walk, []).append(vi)
        ranked = sorted(by_walk.items(), key=lambda kv: (-len(kv[1]), kv[1][0]))
        if ranked[0][0]:
            s["wp"] = list(ranked[0][0])
        if len(ranked) > 1:
            s["wv"] = [[vis, list(walk)] for walk, vis in sorted(ranked[1:], key=lambda kv: kv[1][0])]
        if any(walk for walk in by_walk):
            walk_count += 1


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
        if not v:
            return "{}"
        return "{ " + ", ".join(lua(x) for x in v) + " }"
    if isinstance(v, dict):
        return "{ " + ", ".join(f"{k} = {lua(x)}" for k, x in v.items()) + " }"
    raise TypeError(v)


ORDER = ["k", "t", "q", "o", "ic", "n", "e", "id", "c", "by", "hv", "hq", "m", "x", "y", "r", "spots", "mobs", "mi", "min",
         "pre", "pa", "line", "sk", "bg", "path", "nt", "lvl", "only", "wp", "wv"]
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
walks_said = "walks left out" if args.no_walks else f"{walk_count} with a walk ({leg_count} legs asked)"
print(f"{guide['name']}: {len(WARNINGS)} warning(s), log at most {log_peak}, {len(steps)} steps ({', '.join(f'{k} {c}' for k, c in sorted(counts.items()))}), "
      f"{walks_said}, {len(quests)} quests, {len(variants)} variants -> {path}")
