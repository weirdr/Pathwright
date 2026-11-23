#!/usr/bin/env python3
"""Convert unpacked Forever RXPGuides into a Pathwright companion addon.

    python3 addon/tools/rxp_convert.py "Unpacked guides" --out debug/rxp/Pathwright_RxPForever

Uses the bundled Forever game database and zstd. Builds race/class variants,
resolves includes, and translates locations into Pathwright map coordinates.
Conditions that require RXPGuides at runtime are presented for manual review.
"""
import argparse
from collections import defaultdict
from dataclasses import dataclass
from functools import lru_cache
import json
from pathlib import Path
import re
import sqlite3
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
STEP = re.compile(r"^step\b", re.I)


def split_gate(line):
    # Some exports put the condition before the >> text, most put it after.
    body, separator, tail = line.partition("<<")
    if not separator:
        return line.strip(), ""
    gate, marker, text = tail.partition(">>")
    return (body + marker + text).strip(), gate.strip()


def clean(text):
    text = re.sub(r"\|T.*?\|t|\|A.*?\|a|\|cRXP_[A-Z]+_|\|c[\da-fA-F]{8}|\|r", "", text)
    text = re.sub(r"::\d+", "", text)
    return text.replace("\\n", " ").strip()


@dataclass
class Source:
    group: str
    name: str
    subgroup: str
    gate: str
    next_refs: list
    blocks: list

    @property
    def key(self):
        return self.group + "\\" + self.name

    @property
    def title(self):
        return self.group + " / " + self.name


def read_source(path):
    header, blocks = [], []
    for raw in path.read_text(encoding="utf-8-sig").splitlines():
        line = raw.split("--", 1)[0].strip() if " --" in raw else raw.strip()
        if not line or line.startswith("--"):
            continue
        if STEP.match(line):
            blocks.append([])
        (blocks[-1] if blocks else header).append(line)
    fields = {}
    next_refs = []
    gate = ""
    for line in header:
        content, condition = split_gate(line)
        tag, _, value = content.partition(" ")
        if tag == "#next":
            next_refs.append((value, condition))
        elif tag:
            fields.setdefault(tag, value.strip())
        elif condition:
            gate = condition
    if "#forever" not in fields:
        raise ValueError(f"{path}: expected a Forever guide")
    return Source(fields["#group"], fields["#name"], fields.get("#subgroup", ""), gate, next_refs, blocks)


def expand(source, catalog, stack=(), selection=""):
    if source.key in stack:
        raise ValueError(f"Recursive include of {source.key}")
    blocks = source.blocks
    if selection:
        first, _, last = selection.partition("-")
        labels = {l.removeprefix("#label ").strip(): i for i, b in enumerate(blocks) for l in b if l.startswith("#label ")}
        if first not in labels or (last and last not in labels):
            raise ValueError(f"Missing label in {source.key}@{selection}")
        blocks = blocks[labels[first]:labels[last]+1 if last else None]
    for block in blocks:
        yield block
        for line in block:
            if line.startswith("#include "):
                target, _, selection = line[9:].partition("@")
                key = target if "\\" in target else source.group + "\\" + target
                yield from expand(catalog[key], catalog, (*stack, source.key), selection)


class Game:
    def __init__(self, db):
        self.variants = []
        sql = """select distinct r.ID, c.ID, r.Name_lang, c.Name_lang, r.Alliance
                 from client_charbaseinfo b join client_chrraces r on r.ID=b.RaceID
                 join client_chrclasses c on c.ID=b.ClassID order by r.ID,c.ID"""
        for race, cls, rn, cn, side in db.execute(sql):
            faction = "Horde" if int(side) == 1 else "Alliance"
            tokens = {rn.replace(" ", "").lower(), cn.lower(), faction.lower(), "forever", "enus"}
            if "Skyborne" in rn:
                tokens.add("skyborne")
            self.variants.append((dict(race=int(race), **{"class": int(cls)}, faction=faction), frozenset(tokens)))
        self.maps = dict(db.execute("select ID,Name_lang from client_uimap"))
        self.map_ids = {name: int(mid) for mid, name in db.execute(
            "select ID,Name_lang from client_uimap where System=0 order by (Type=3),ID desc")}
        self.bounds = {(int(m),int(c)): (left,top,right,bottom) for m,c,left,top,right,bottom in db.execute(
            "select UiMapID,MapID,Region_4,Region_3,Region_1,Region_0 from client_uimapassignment where OrderIndex=0")}
        self.continents = {mid: continent for mid, continent in self.bounds}
        self.areas = dict(db.execute("select ID,AreaName_lang from client_areatable"))
        self.spells = dict(db.execute("select ID,Name_lang from client_spellname"))
        self.quests = dict(db.execute("select id,name from m_quest"))
        self.items = dict(db.execute("select id,name from m_item"))
        self.npcs = dict(db.execute("select id,name from m_npc"))
        objects = dict(db.execute("select id,name from m_object"))
        entities = {"item": self.items, "object": objects, "creature": self.npcs, "talk": self.npcs}
        self.objectives = {}
        for quest, slot, kind, eid, count, text in db.execute(
                "select quest_id, idx, type, target_id, amount, text from m_quest_objective"):
            name = entities.get(kind, {}).get(eid) or text
            if name:
                target = dict(n=name)
                if kind in entities and eid:
                    target.update(e="npc" if kind in ("creature", "talk") else kind, id=eid)
                if count:
                    target["c"] = count
                self.objectives[quest, slot] = target

    def point(self, args):
        zone, x, y = args[:3]
        zone, slash, continent = zone.partition("/")
        mid = int(zone) if zone.isdigit() else self.map_ids[zone]
        x, y = float(x), float(y)
        if slash:
            left, top, right, bottom = self.bounds[mid, int(continent)]
            x, y = (left-x)*100/(left-right), (top-y)*100/(top-bottom)
        # Some boundary points lie just off the named zone's map. Keep the
        # world location on its continent's map so the arrow stays usable.
        if slash and not (0 <= x <= 100 and 0 <= y <= 100):
            continent_map = {"0": "1415", "1": "1414"}.get(continent)
            if continent_map and str(mid) != continent_map:
                return self.point([continent_map + slash + continent, *args[1:]])
        return dict(m=mid, x=round(x, 3), y=round(y, 3))

    def world(self, point):
        mid = point["m"]
        left, top, right, bottom = self.bounds[mid, self.continents[mid]]
        return [round(top+(bottom-top)*point["y"]/100, 2), round(left+(right-left)*point["x"]/100, 2)]


@lru_cache(maxsize=None)
def matches(condition, tokens):
    if not condition:
        return True
    # The importer's slash-separated alternatives consist of ANDed tokens.
    return any(all((word.lstrip("!") in tokens) != word.startswith("!")
                   for word in re.findall(r"!?\w+", clause.lower())) for clause in condition.split("/"))


def line_parts(line):
    body, _, text = line.partition(">>")
    tag, _, arg = body.strip().partition(" ")
    return tag, arg.strip(), clean(text)


def remap_quests(line, aliases):
    """Faction quest substitutions, scoped to a single guide and variant."""
    if not aliases:
        return line
    body, marker, caption = line.partition(">>")
    tag, _, args = body.partition(" ")
    values = args.split(",")
    if tag in QUEST_KINDS:
        indices = [0]
    elif tag == ".collect" and len(values) > 2:
        indices = [2]
    elif tag.startswith(".is") or tag in (".daily", ".dailyturnin"):
        indices = range(len(values))
    else:
        return line
    for i in indices:
        values[i] = aliases.get(values[i].strip(), values[i])
    return tag + " " + ",".join(values) + marker + caption


def num(s):
    return int(s) if re.fullmatch(r"-?\d+", s) else None


def lua(value):
    if isinstance(value, str):
        # JSON's escapes for quotes and slashes match Lua; keep UTF-8 literal.
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, dict):
        return "{ " + ", ".join(f'["{k}"] = {lua(v)}' for k, v in value.items()) + " }"
    if isinstance(value, list):
        return "{ " + ", ".join(map(lua, value)) + " }"
    if isinstance(value, bool):
        return str(value).lower()
    return str(value)


QUEST_KINDS = {".accept": ("accept", "Accept"), ".complete": ("objective", "Complete"),
               ".turnin": ("turnin", "Turn in"), ".abandon": ("abandon", "Abandon")}
SERVICES = {".fly": ("fly", "Fly to"), ".fp": ("flight_master", "Learn the flight path"),
            ".home": ("bind", "Set your hearthstone"), ".hs": ("hearth", "Use your hearthstone"),
            ".deathskip": ("deathskip", "Respawn at the spirit healer"), ".trainer": ("train", "Visit the trainer")}
REQUIRE = {".isOnQuest": "Quest in log", ".isNotOnQuest": "Quest absent from log",
           ".isQuestComplete": "Quest ready to turn in", ".isQuestNotComplete": "Quest incomplete",
           ".isQuestTurnedIn": "Quest already turned in", ".isQuestAvailable": "Quest available",
           ".itemcount": "Item count", ".itemStat": "Equipped item check", ".money": "Gold check",
           ".maxlevel": "Maximum level", ".skill": "Skill check", ".cooldown": "Cooldown check",
           ".reputation": "Reputation check", ".bindlocation": "Hearthstone binding check",
           ".dungeon": "Dungeon route enabled", ".group": "Group route", ".solo": "Solo route",
           "#ah": "Auction-house route", "#ssf": "Self-found route", "#requires": "After step",
           "#xprate": "XP rate", ".enabledungeon": "Dungeon route setting"}

# Two chapter references in the Forever export use older names. Prefer the
# literal name if a future export supplies it, then try the same group's alias.
NEXT_ALIASES = {"26-31 Duskwood Mage AoE": "26-31 Duskwood Part 2 Mage AoE",
                "43-44 Riverglades": "42-44 Riverglades"}


def distinct(values):
    return list(dict.fromkeys(v for v in values if v))


def convert_block(lines, game):
    hints, actions, points, conditions, mobs, targets = [], [], [], [], [], []
    overlay = []
    background = optional = loop = False
    mode = None
    for line in lines:
        tag, arg, text = line_parts(line)
        args = [s.strip() for s in arg.split(",")]
        first = num(args[0])
        if tag == "#phase":
            lo, _, hi = arg.partition("-")
            if not int(lo) <= 5 <= int(hi or 999):
                return []
        elif tag == "#som" or tag == "#wotlk" or (tag == "#season" and "0" not in args):
            return []
        elif tag == "#loop":
            loop = True
        elif tag == ".convertquest":
            continue
        elif tag in ("#hardcore", "#hardcoreserver", "#softcore", "#softcoreserver"):
            mode = "hardcore" if "hardcore" in tag else "softcore"
        elif tag.startswith(("#completewit", "#sticky")):
            background = True
        elif tag == "#optional":
            optional = True
        elif tag in (".zoneskip", ".subzoneskip"):
            zone = (game.maps if tag == ".zoneskip" else game.areas).get(first, args[0])
            flags = num(args[1]) if len(args) > 1 else 0
            conditions.append(("Only in " if (flags or 0) & 1 else "Skip in ") + str(zone))
        elif tag == ".bindlocation":
            reverse = len(args) > 1 and (num(args[1]) or 0) & 1
            conditions.append(("Only if bound to " if reverse else "Skip if bound to ") + game.areas.get(first, args[0]))
        elif tag in REQUIRE:
            detail = arg
            if tag.startswith(".is") and all(num(i) for i in args):
                detail = " or ".join(game.quests.get(int(i), i) for i in args)
            elif tag == ".itemcount" and first in game.items:
                detail = ", ".join([game.items[first], *args[1:]])
            conditions.append(" ".join(filter(None, [REQUIRE[tag], detail])))
        elif tag == ".xp" and len(args) > 1:
            threshold = args[0].lstrip("<>")
            below = args[0].startswith("<") or args[1].startswith("-")
            conditions.append(("Skip below " if below else "Skip at or above ") + "level " + threshold)
        elif tag == ".train" and len(args) > 1 and num(args[1]) and int(args[1]) & 1:
            conditions.append(("Spell known: " if int(args[1]) & 2 else "Spell unlearned: ") + game.spells.get(first, args[0]))
        elif tag == ".line":
            overlay.extend(game.point([args[0], x, y]) for x, y in zip(args[1::2], args[2::2]))
        elif tag in (".goto", ".waypoint", ".pin"):
            p = game.point(args)
            radius = float(args[3]) if len(args)>3 and re.fullmatch(r"-?[\d.]+", args[3]) else 0
            points.append((p, radius, text, len(args) > 4))
            continue
        elif tag in (".target", ".mob", ".unitscan"):
            name, _, eid = arg.lstrip("+").partition("::")
            (targets if tag == ".target" else mobs).append((name, num(eid)))
        elif tag in QUEST_KINDS and first:
            kind, verb = QUEST_KINDS[tag]
            q = abs(first)
            s = dict(k=kind, q=q)
            title = game.quests.get(q) or f"quest {q}"
            default = verb + " " + title
            if kind == "objective" and len(args)>1 and num(args[1]):
                slot = int(args[1])
                s.update(o=slot, **game.objectives.get((q, slot), {}))
                default = f"{title} — " + (s.get("n") or f"objective {slot}")
                if background:
                    s["bg"] = True
                if len(args)>2 and num(args[2]) and int(args[2])>0:
                    default += " (partial objective: " + args[2] + ")"
                    s["k"] = "note"
                if first < 0:
                    conditions.append("Quest in log " + title)
            s["t"] = text or default
            if kind == "accept" and len(args) > 1 and num(args[1]) and int(args[1]) & 1:
                # This flag explicitly calls for a manual pickup (often an escort).
                s["k"] = "note"
            if kind == "turnin" and len(args) > 1 and (num(args[1]) or 0) > 0:
                s.update(k="note", t=s["t"] + f" (reward choice {args[1]})")
            if kind == "turnin" and len(args) > 2 and (num(args[2]) or 0) & 1:
                s["k"] = "note"
            actions.append(s)
            continue
        elif tag in SERVICES:
            kind, fallback = SERVICES[tag]
            actions.append(dict(k=kind, t=text or (fallback + " " + arg).strip()))
            continue
        elif tag == ".train" and first:
            actions.append(dict(k="train", sp=[first], t=text or f"Train spell {first}"))
            continue
        elif tag == ".xp" and re.fullmatch(r"\d+(?:\+\d+)?", arg):
            level, _, xp = arg.partition("+")
            s = dict(k="grind", lvl=int(level), t=text or f"Reach level {arg}")
            if xp:
                s["xp"] = int(xp)
            actions.append(s)
            continue
        elif tag == ".collect" and first:
            name = game.items.get(first) or f"item {first}"
            hints.append(text or f"Collect {args[1] if len(args)>1 else '1'} × {name}.")
            continue
        elif tag == ".link":
            hints.append((text + " " + arg).strip())
            continue
        elif tag.startswith(("+","*")):
            hints.append(clean(line.lstrip("+* ")))
            continue
        elif tag in (".zone", ".subzone", ".xp", ".use", ".cast", ".destroy", ".vendor") and not text:
            label = {".zone":"Travel to", ".subzone":"Enter area", ".xp":"Reach XP target",
                     ".use":"Use", ".cast":"Cast spell", ".destroy":"Discard", ".vendor":"Visit the merchant"}[tag]
            detail = (game.items.get(first) if tag in (".use",".destroy") else
                      game.maps.get(first) if tag == ".zone" else None)
            hints.append((label + " " + (detail or arg)).strip())
        elif not text and tag.startswith(".") and tag not in {
                ".skipgossip", ".skipgossipid", ".disablecheckbox", ".showwhiledead", ".line",
                ".timer", ".addquestitem", ".usespell"}:
            hints.append((tag[1:] + " " + arg).strip())
        elif not text and tag and tag[0] not in "#.":
            hints.append(clean(line))
        if text:
            hints.append(text)

    hints = distinct(hints)
    lead = []
    if not points and overlay:
        points.append((overlay.pop(0), 0, "", True))
    if points:
        p, radius, caption, _ = points[-1]
        for intermediate, r, instruction, arrow_only in points[:-1]:
            if (r > 0 and not arrow_only and not loop and not background and not conditions and not optional) or instruction:
                lead.append(dict(k="goto", t=instruction or "Follow the route", r=max(r, 10), **intermediate))
        if caption:
            hints.insert(0, caption)
        if not actions and not hints:
            actions.append(dict(k="goto", t=caption or "Reach the waypoint", r=radius if radius>0 else 15))
    if not actions and hints:
        actions.append(dict(k="note", t=hints.pop(0)))
    for s in actions:
        if points:
            s.update(points[-1][0])
            others = [pt for pt, r, _, _ in points[:-1] if (loop or r <= 0) and pt != points[-1][0]]
            others.extend(pt for pt in overlay if pt not in others and pt != p)
            if others:
                s["spots"] = others
            if not loop:
                path = [pt for pt, r, _, arrow_only in points[:-1] if r > 0 and arrow_only
                        and game.continents[pt["m"]] == game.continents[p["m"]]]
                if path:
                    s["wp"] = [coord for pt in path for coord in game.world(pt)]
        if s["k"] == "objective" and mobs:
            s["mobs"] = distinct(name for name, _ in mobs)
            ids = distinct(eid for _, eid in mobs)
            if ids:
                s["mi"] = ids
        if targets and s["k"] not in ("objective", "grind"):
            name, eid = targets[0]
            s.update(n=name)
            if eid:
                s.update(e="npc", id=eid)
        if hints:
            s["nt"] = [dict(l=1, t=h) for h in hints]
    for s in lead + actions:
        if mode:
            s["rxpMode"] = mode
        if conditions or optional:
            # A quest action here could auto-accept or advance before the
            # player checked the original live conditions. Use a manual step.
            prefix = ("Optional. " if optional else "") + ". ".join(distinct(conditions))
            s["t"] = prefix.rstrip(". ") + ". " + s["t"]
            s["k"] = "note"
            for key in ("q", "o", "sp", "bg", "lvl", "xp"):
                s.pop(key, None)
        elif background and not s.get("bg"):
            s["t"] = "Along the way: " + s["t"]
    return lead + actions


def make_guide(source, catalog, game):
    variants = [(v, tokens) for v, tokens in game.variants if matches(source.gate, tokens)]
    levels = re.search(r"(\d{1,2})\s*-\s*(\d{1,2})", source.name) or re.search(
        r"(\d{1,2})\s*-\s*(\d{1,2})", source.subgroup)
    low, high = (int(levels[1]), int(levels[2])) if levels else (1, 60)
    steps = []
    blocks = list(expand(source, catalog))
    aliases = [dict() for _ in variants]
    for block in blocks:
        if any(line.startswith(".convertquest ") for line in block):
            for i, (_, tokens) in enumerate(variants):
                if matches(split_gate(block[0])[1], tokens):
                    for line in block[1:]:
                        command, gate = split_gate(line)
                        if command.startswith(".convertquest ") and matches(gate, tokens):
                            old, new = command.split()[1].split(",")
                            aliases[i][old] = new
    has_aliases = any(aliases)
    for block in blocks:
        _, gate = split_gate(block[0])
        lines = [split_gate(line) for line in block[1:]]
        by_lines = defaultdict(list)
        if not has_aliases and not gate and not any(g for _, g in lines):
            by_lines[tuple(line for line, _ in lines)] = list(range(1, len(variants)+1))
        else:
            for index, (_, tokens) in enumerate(variants, 1):
                if matches(gate, tokens):
                    selected = tuple(remap_quests(line, aliases[index-1]) for line, g in lines if matches(g, tokens))
                    by_lines[selected].append(index)
        for selected, indices in by_lines.items():
            for step in convert_block(selected, game):
                if len(indices) != len(variants):
                    step["only"] = indices
                steps.append(step)
    if not steps or not variants:
        raise ValueError(f"Empty conversion: {source.key}")
    guide = dict(name=source.title, origin="RXPGuides / " + source.group, fromLevel=low, toLevel=high,
                 locale="enUS", version=1, format=2, variants=[v for v, _ in variants])
    following = defaultdict(list)
    for index, (_, tokens) in enumerate(variants, 1):
        for value, gate in source.next_refs:
            if not matches(gate, tokens):
                continue
            names = []
            for ref in value.split(";"):
                ref = ref.strip()
                key = ref if "\\" in ref else source.group + "\\" + ref
                if key not in catalog and ref in NEXT_ALIASES:
                    key = source.group + "\\" + NEXT_ALIASES[ref]
                if key in catalog and matches(catalog[key].gate, tokens):
                    names.append(catalog[key].title)
            if names:
                following[names[0]].append(index)
                break
    for name, indices in following.items():
        if len(indices) == len(variants):
            guide["next"] = name
        else:
            steps.append(dict(k="note", t="Continue with " + name, only=indices))
    return guide, steps


def build(folder, output, game):
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", output.name):
        raise ValueError("Choose an addon folder name using letters, digits and underscores")
    paths = sorted(folder.rglob("*.txt"))
    sources = [read_source(p) for p in paths]
    catalog = {s.key: s for s in sources}
    if not sources or len(catalog) != len(sources):
        raise ValueError("Expected one or more uniquely named guides in each group")
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        raise ValueError(f"Choose a new output directory ({output} already exists)")
    with tempfile.TemporaryDirectory(dir=output.parent) as tmp:
        stage = Path(tmp) / output.name
        stage.mkdir()
        manifest = ["## Interface: 16001", "## Title: Pathwright - RXPGuides Forever",
                    "## Notes: Converted Forever routes for Pathwright Guide.", "## Dependencies: Pathwright_Guide",
                    "## Group: Pathwright_Profile", r"## IconTexture: Interface\AddOns\Pathwright_Profile\Media\Logo",
                    "", "Register.lua"]
        (stage / "Register.lua").write_text("""local _, pack = ...
local hardcore = C_GameRules and C_GameRules.IsHardcoreActive and C_GameRules.IsHardcoreActive()
local mode = hardcore and "hardcore" or "softcore"
function pack.Register(guide)
    local steps = {}
    for _, step in ipairs(guide.steps) do
        if not step.rxpMode or step.rxpMode == mode then
            step.rxpMode = nil
            steps[#steps+1] = step
        end
    end
    guide.steps = steps
    Pathwright.Builtin.Register(guide)
end
""")
        total = 0
        for i, source in enumerate(sources, 1):
            if not source.blocks:
                print(f"Skipped empty source: {source.key}")
                continue
            guide, steps = make_guide(source, catalog, game)
            total += len(steps)
            slug = re.sub(r"[^a-zA-Z0-9]+", "_", source.name).strip("_")[:75]
            file = f"{i:03}_{slug}.lua"
            manifest.append(file)
            with (stage / file).open("w", encoding="utf-8") as out:
                out.write("local _, pack = ...\npack.Register({\n")
                for k, v in guide.items():
                    out.write(f'    {k} = {lua(v)},\n')
                out.write("    steps = {\n")
                for s in steps:
                    out.write("        " + lua(s) + ",\n")
                out.write("    },\n})\n")
        (stage / (output.name + ".toc")).write_text("\n".join(manifest)+"\n", encoding="utf-8")
        stage.rename(output)
    print(f"Converted {sum(bool(s.blocks) for s in sources)} guides ({total:,} step entries across variants) to {output}")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("source", type=Path)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--db", type=Path, default=ROOT / "data/forever.sqlite.zst")
    args = p.parse_args()
    with tempfile.TemporaryDirectory() as tmp:
        dbpath = args.db
        if dbpath.suffix == ".zst":
            plain = Path(tmp)/"forever.sqlite"
            with plain.open("wb") as out:
                subprocess.run(["zstd", "-dc", dbpath], stdout=out, check=True)
            dbpath = plain
        with sqlite3.connect(dbpath.resolve().as_uri() + "?mode=ro", uri=True) as db:
            build(args.source, args.out, Game(db))
