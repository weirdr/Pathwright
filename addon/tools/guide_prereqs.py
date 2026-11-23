#!/usr/bin/env python3
"""Check that every built-in guide only sends a character to take a quest it can take.

    python3 -I addon/tools/guide_prereqs.py [--all]

It reads the built guides (addon/Pathwright_Guide/Builtin/*.lua, through luajit) and follows
each character (race and class) along each chain of guides linked by `next`, from its first
guide: the quests handed in so far are those it has done. At each accept step, the quest's
prerequisites as the guide gives them (`pre`: all of them, `pa`: any one; `nopre` and `after`
in the script already changed them) must be done by then. Otherwise:
- order: the prerequisite is handed in later (in this guide or a later one of the chain);
- absent: no guide of the chain before it hands the prerequisite in.

A guide no other guide names as its `next` and that is not a starter (a zone guide: Mount
Hyjal, the Fallen Hero...) is checked as played after the whole leveling chain of the
character's race: the quests that chain hands in count as done.

It exits with 1 when it finds a problem. --all also lists the steps it passed.
"""
import glob, json, os, subprocess, sys, tempfile
from collections import defaultdict

DUMP = r"""
local defs = {}
Pathwright = { Builtin = { Register = function(d) defs[#defs + 1] = d end } }
for _, f in ipairs(arg) do dofile(f) end
local function enc(v)
  local t = type(v)
  if t == "table" then
    if #v > 0 or next(v) == nil then
      local o = {}
      for i, x in ipairs(v) do o[i] = enc(x) end
      return "[" .. table.concat(o, ",") .. "]"
    end
    local o = {}
    for k, x in pairs(v) do o[#o + 1] = string.format("%q", tostring(k)) .. ":" .. enc(x) end
    return "{" .. table.concat(o, ",") .. "}"
  elseif t == "string" then return string.format("%q", v)
  elseif t == "boolean" or t == "number" then return tostring(v)
  end
  return "null"
end
local out = {}
for _, d in ipairs(defs) do
  local steps = {}
  for _, s in ipairs(d.steps) do
    steps[#steps + 1] = { k = s.k, q = s.q, pre = s.pre, pa = s.pa, pn = s.pn, only = s.only, t = s.t }
  end
  out[#out + 1] = { name = d.name, next = d.next, from = d.fromLevel, variants = d.variants, steps = steps }
end
io.write(enc(out))
"""

files = sorted(glob.glob("addon/Pathwright_Guide/Builtin/*.lua"))
# luajit runs the first argument after -e as a script: run the dumper from a file instead.
with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as f:
    f.write(DUMP)
try:
    raw = subprocess.run(["luajit", f.name] + files, capture_output=True, text=True, check=True).stdout
finally:
    os.unlink(f.name)
raw = raw.replace("\\\n", "\\n")
guides = {g["name"]: g for g in json.loads(raw, strict=False)}
assert len(guides) == len(files), f"read {len(guides)} guides from {len(files)} files"

STARTERS = {2: "Orc & Troll Starter (1-13)", 8: "Orc & Troll Starter (1-13)", 5: "Undead Starter (1-13)",
            6: "Tauren Starter (1-13)", 95: "Skyborne Starter (1-13)", 96: "Skyborne Starter (1-13)"}


def next_of(g, faction):
    n = g.get("next")
    if isinstance(n, dict):
        return n.get(faction)
    return n


def chain(first, faction):
    out, name = [], first
    while name and name in guides and name not in out:
        out.append(name)
        name = next_of(guides[name], faction)
    return out


def variant_index(g, race, cls):
    for i, v in enumerate(g["variants"], 1):
        if v["race"] == race and v["class"] == cls:
            return i
    return None


def steps_for(g, vi):
    return [s for s in g["steps"] if not s.get("only") or vi in s["only"]]


def walk(names, race, cls, faction, done, report):
    """Follow one character along `names`; `done` grows with the quests handed in."""
    handed_later = {}
    for gi, name in enumerate(names):
        g = guides[name]
        vi = variant_index(g, race, cls)
        if vi is None:
            continue
        for si, s in enumerate(steps_for(g, vi)):
            if s["k"] == "turnin":
                handed_later.setdefault(s["q"], (gi, si))
    for gi, name in enumerate(names):
        g = guides[name]
        vi = variant_index(g, race, cls)
        if vi is None:
            continue
        for si, s in enumerate(steps_for(g, vi)):
            if s["k"] == "accept" and report is not None:
                missing = [p for p in (s.get("pre") or []) if p not in done]
                pa = s.get("pa") or []
                need = min(s.get("pn") or 1, len(pa)) if pa else 0
                if pa and sum(1 for p in pa if p in done) < need:
                    missing.append(tuple(pa))
                for p in missing:
                    ps = p if isinstance(p, tuple) else (p,)
                    later = [handed_later[x] for x in ps if x in handed_later]
                    kind = "order" if later else "absent"
                    report[(name, s["q"], p, kind)].add((race, cls))
            if s["k"] == "turnin":
                done.add(s["q"])
    return done


named = {n for g in guides.values() for n in ([g["next"]] if isinstance(g.get("next"), str) else
                                              list((g.get("next") or {}).values()))}
roots = [n for n in guides if n not in named]
starters = set(STARTERS.values())
report = defaultdict(set)

# The leveling chains: each starter's characters.
leveled = {}
for race, first in STARTERS.items():
    faction = "Alliance" if race == 95 else "Horde"
    names = chain(first, faction)
    for v in guides[first]["variants"]:
        if v["race"] != race:
            continue
        leveled[(race, v["class"])] = walk(names, race, v["class"], faction, set(), report)

# Zone guides: after the leveling chain of the character's race.
for root in sorted(set(roots) - starters):
    names = chain(root, "Horde")
    for v in guides[root]["variants"]:
        base = set(leveled.get((v["race"], v["class"]), set()))
        walk(names, v["race"], v["class"], v["faction"], base, report)

qname = {}
try:
    import sqlite3
    db = sqlite3.connect("data/forever.sqlite")
    qname = dict(db.execute("select id, name from m_quest"))
except Exception:
    pass


def label(q):
    if isinstance(q, tuple):
        return " or ".join(label(x) for x in q)
    return f"{q} {qname.get(q, '')}".strip()


for (name, q, p, kind), who in sorted(report.items(), key=lambda kv: (kv[0][0], str(kv[0][1]))):
    races = sorted({r for r, _ in who})
    print(f"{kind}: {name}: accept {label(q)} needs {label(p)} ({len(who)} race/class, races {races})")
print(f"{len(report)} problem(s)")
sys.exit(1 if report else 0)
