#!/usr/bin/env python3
"""Check the shipped guides against the game data.

    python3 addon/tools/guide_validate.py [-v] [--db data/forever.sqlite.zst]
        [--allow addon/tools/guide_validate.allow] [guide dir or file ...]

Reads every guide of addon/Pathwright_Guide/Builtin and addon/Pathwright_RxPForever (through
addon/tools/guide_dump.lua: the guide files are Lua, run by luajit or lua) and reports, per guide
and step:

  errors (the exit code is 1)
    quest-missing    a quest that is not in m_quest
    quest-removed    a quest whose status is "removed"
    next-dangling    a "next" guide that does not exist
    guide-duplicate  two guides with one name ("next" could mean either)
  warnings
    quest-incomplete a quest whose status is "incomplete"
    quest-no-client  a quest with in_client = 0 (the game client does not know it)
    min-level        a quest taken below its min_level (at the step's level, "lvl", when the guide
                     gives one; else at the guide's last level)
    race-class       a quest step for characters its races_mask / classes_mask leave out
    prereq-order     a quest taken before a prerequisite (m_quest_link pre_all / pre_any) that the
                     guide hands in later
    prereq-absent    ... that neither the guide nor the guides leading to it ("next") hand in
    map-unknown      a place on a uiMap that is not in client_uimap
    coord-range      a place outside its map (not within 0-100)
    next-gap         a "next" guide that starts above this one's last level, or ends below its first
    next-cycle       a "next" chain that comes back to this guide
    mobs-text        a "mobs" entry that is objective text ("... slain", "... (15)"), not a mob name
    allow-unused     a line of the allowlist that matched nothing

Without -v the warnings are counted by check; -v lists each. The allowlist holds the accepted
exceptions, one per line, each with its reason:

    <check> <guide file name without .lua, or *> <quest id, or *>   # why it is accepted

The masks: races_mask bit (race id - 1) for the classic races, bits 32 and 33 for the two Skyborne
races of WoW Forever (95 High Order, 96 Windshaper; overrides/forever/races.toml). As
guide_build.py does, a class quest is checked by its class mask alone, and a classic mask naming a
whole faction (77, 178) is taken to include that faction's Skyborne.
"""
import argparse
from collections import Counter, defaultdict
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_DIRS = [ROOT / "addon/Pathwright_Guide/Builtin", ROOT / "addon/Pathwright_RxPForever"]
ERRORS = {"quest-missing", "quest-removed", "next-dangling", "guide-duplicate", "allow-syntax"}
SKYBORNE_BITS = {95: 1 << 32, 96: 1 << 33}
FACTION_MASKS = {95: 77, 96: 178}  # every classic race of the Skyborne race's faction
OBJECTIVE_TEXT = re.compile(r"\bslain\b|\(\d+\)\s*$|\b\d+\s*/\s*\d+\s*$", re.I)


def load_guides(paths):
    """The guides of the given directories and files, in file order."""
    lua = next((exe for exe in ("luajit", "lua", "lua5.4", "lua5.1") if shutil.which(exe)), None)
    if not lua:
        sys.exit("guide_validate: luajit (or lua) is needed to read the guides")
    files = []
    for p in paths:
        p = Path(p)
        # Register.lua is the pack's loader, not a guide.
        files += sorted(f for f in p.glob("*.lua") if f.name != "Register.lua") if p.is_dir() else [p]
    if not files:
        sys.exit("guide_validate: no guide files")
    run = subprocess.run([lua, str(ROOT / "addon/tools/guide_dump.lua"), *map(str, files)],
                         capture_output=True, text=True, encoding="utf-8")
    if run.returncode:
        sys.exit("guide_validate: " + run.stderr.strip())
    guides = [json.loads(line) for line in run.stdout.splitlines()]
    for g in guides:
        g["stem"] = Path(g["file"]).stem
        g["rel"] = os.path.relpath(g["file"], ROOT)
        # An empty Lua table is dumped as a list.
        g["steps"] = g.get("steps") or []
        g["variants"] = g.get("variants") or []
    return guides


class Game:
    def __init__(self, db):
        self.quests = {}
        for qid, name, minl, races, classes, status, in_client in db.execute(
                "select id, name, min_level, races_mask, classes_mask, status, in_client from m_quest"):
            self.quests[qid] = dict(name=name, min=minl or 0, races=int(races or 0), classes=int(classes or 0),
                                    status=status, in_client=in_client)
        self.pre_all, self.pre_any = defaultdict(list), defaultdict(list)
        for qid, kind, other in db.execute(
                "select quest_id, kind, other_id from m_quest_link where kind in ('pre_all', 'pre_any')"):
            (self.pre_all if kind == "pre_all" else self.pre_any)[qid].append(other)
        for qid, any_of in self.pre_any.items():
            self.pre_any[qid] = [o for o in any_of if o not in self.pre_all.get(qid, ())]
        self.maps = {int(i) for (i,) in db.execute("select ID from client_uimap")}
        # Maps whose coordinates the data places in the world: only those can be range checked.
        self.placed_maps = {int(i) for (i,) in db.execute("select distinct UiMapID from client_uimapassignment")}
        self.races = {int(i): n for i, n in db.execute("select ID, Name_lang from client_chrraces")}
        self.classes = {int(i): n for i, n in db.execute("select ID, Name_lang from client_chrclasses")}

    def open_to(self, qid, race, cls):
        """Whether a character of that race and class can take the quest, by its masks."""
        q = self.quests[qid]
        if q["classes"]:
            return bool(q["classes"] & (1 << (cls - 1)))
        mask = q["races"]
        if not mask:
            return True
        if race in SKYBORNE_BITS:
            return bool(mask & SKYBORNE_BITS[race]) or mask & FACTION_MASKS[race] == FACTION_MASKS[race]
        return bool(mask & (1 << (race - 1)))

    def who(self, chars):
        """A short description of a set of (race, class): "Orc, Troll" or "Orc Warrior, ...". """
        by_race = defaultdict(set)
        for race, cls in chars:
            by_race[race].add(cls)
        names = [self.races.get(r, f"race {r}") for r in sorted(by_race)]
        if len(chars) <= 3:
            names = [f"{self.races.get(r, r)} {self.classes.get(c, c)}" for r, c in sorted(chars)]
        return ", ".join(names)


class Report:
    def __init__(self, allow_path):
        self.findings = []
        self.allowed = 0
        self.allow = []  # [check, guide, subject, line number, used]
        self.allow_path = allow_path
        if allow_path and allow_path.exists():
            rel = os.path.relpath(allow_path, ROOT)
            for n, line in enumerate(allow_path.read_text(encoding="utf-8").splitlines(), 1):
                entry, _, reason = line.partition("#")
                words = entry.split()
                if not words:
                    continue
                if len(words) != 3 or not reason.strip():
                    self.findings.append(("allow-syntax", f"{rel}:{n}", "<check> <guide> <quest> # reason"))
                    continue
                self.allow.append([*words, n, False])

    def add(self, check, guide, step, subject, message):
        """A finding on a guide (step: its number, or None), about a subject (a quest id, or None)."""
        for entry in self.allow:
            if entry[0] == check and entry[1] in ("*", guide["stem"]) and entry[2] in ("*", str(subject)):
                entry[4] = True
                self.allowed += 1
                return
        where = guide["rel"] + (f": step {step}" if step else "")
        self.findings.append((check, where, message))

    def finish(self, verbose):
        rel = self.allow_path and os.path.relpath(self.allow_path, ROOT)
        for check, guide, subject, n, used in self.allow:
            if not used:
                self.findings.append(("allow-unused", f"{rel}:{n}", f"{check} {guide} {subject} matched nothing"))
        errors = [f for f in self.findings if f[0] in ERRORS]
        warnings = [f for f in self.findings if f[0] not in ERRORS]
        for check, where, message in errors:
            print(f"{where}: error [{check}] {message}")
        if verbose:
            for check, where, message in warnings:
                print(f"{where}: warning [{check}] {message}")
        elif warnings:
            counts = Counter(f[0] for f in warnings)
            print("warnings (-v lists them): " + ", ".join(f"{c} {n}" for c, n in sorted(counts.items())))
        print(f"guide_validate: {len(errors)} error(s), {len(warnings)} warning(s), {self.allowed} allowed")
        return 1 if errors else 0


def chars_of(guide, step):
    """The (race, class) characters a step is for: its "only" variants, or all of the guide's."""
    variants = guide["variants"]
    only = step.get("only")
    picked = [variants[i - 1] for i in only if 0 < i <= len(variants)] if only else variants
    return {(v["race"], v["class"]) for v in picked}


def hands_in(step):
    """The quest a step hands in. A converted RestedXP turn-in that needs a look first is a "note"
    with the quest: counted too, so that a prerequisite is not reported missing by mistake."""
    return step.get("q") if step["k"] in ("turnin", "note") else None


def check_steps(guide, game, report, before):
    """The checks of one guide's steps. `before`: (race, class) -> the quests handed in by the guides
    leading to this one."""
    last_level = guide.get("toLevel")
    handed_later = defaultdict(set)  # quest -> the characters some step of this guide hands it in for
    for step in guide["steps"]:
        if hands_in(step):
            handed_later[step["q"]] |= chars_of(guide, step)
    done = defaultdict(set, {c: set(qs) for c, qs in before.items()})
    for qid in guide.get("carry") or []:
        if qid not in game.quests:
            report.add("quest-missing", guide, None, qid, f"carried quest {qid} is not in the game data")

    for n, step in enumerate(guide["steps"], 1):
        kind, qid = step["k"], step.get("q")
        chars = chars_of(guide, step)

        # Places: the step's own, and the other spots of its objective.
        for place in [step, *(step.get("spots") or [])]:
            m, x, y = place.get("m"), place.get("x"), place.get("y")
            if m is None:
                continue
            if m not in game.maps:
                report.add("map-unknown", guide, n, None, f"uiMap {m} is not in the game data ({step['t'][:50]})")
            elif m in game.placed_maps and not (0 <= x <= 100 and 0 <= y <= 100):
                report.add("coord-range", guide, n, None, f"{x},{y} is outside uiMap {m} ({step['t'][:50]})")

        for mob in step.get("mobs") or []:
            if OBJECTIVE_TEXT.search(mob):
                report.add("mobs-text", guide, n, qid, f'mob "{mob}" is objective text, not a mob name')

        if qid is None:
            continue
        q = game.quests.get(qid)
        if not q:
            report.add("quest-missing", guide, n, qid, f"{kind} quest {qid} is not in the game data")
            continue
        label = f"{kind} {qid} {q['name']}"
        if q["status"] == "removed":
            report.add("quest-removed", guide, n, qid, f"{label}: the quest is removed")
        elif q["status"] == "incomplete":
            report.add("quest-incomplete", guide, n, qid, f"{label}: the quest's data is incomplete")
        if q["in_client"] == 0:
            report.add("quest-no-client", guide, n, qid, f"{label}: not in the game client (in_client = 0)")

        if kind in ("accept", "turnin", "objective"):
            shut = {c for c in chars if not game.open_to(qid, *c)}
            if shut:
                report.add("race-class", guide, n, qid,
                           f"{label}: not for {len(shut)} of its {len(chars)} characters ({game.who(shut)}); "
                           f"races_mask {q['races']}, classes_mask {q['classes']}")

        if kind == "accept":
            level = step.get("lvl") or last_level
            if level and q["min"] > level:
                at = "the step's level" if step.get("lvl") else "the guide's last level"
                report.add("min-level", guide, n, qid, f"{label}: needs level {q['min']}, {at} is {level}")

            # Prerequisites, for each character of the step: only those the character can do.
            late, absent = defaultdict(set), defaultdict(set)
            for c in chars:
                if not game.open_to(qid, *c):
                    continue
                doable = lambda p: p in game.quests and game.quests[p]["status"] != "removed" and game.open_to(p, *c)
                needs = [p for p in game.pre_all.get(qid, ()) if doable(p) and p not in done[c]]
                any_of = [p for p in game.pre_any.get(qid, ()) if doable(p)]
                if any_of and not any(p in done[c] for p in any_of):
                    needs.append(tuple(any_of))
                for need in needs:
                    ids = need if isinstance(need, tuple) else (need,)
                    (late if any(c in handed_later[p] for p in ids) else absent)[need].add(c)
            for check, found in (("prereq-order", late), ("prereq-absent", absent)):
                for need, who in found.items():
                    ids = need if isinstance(need, tuple) else (need,)
                    names = " or ".join(f"{p} {game.quests[p]['name']}" for p in ids[:4]) + (" ..." if len(ids) > 4 else "")
                    said = ("is handed in later in this guide" if check == "prereq-order"
                            else "is not handed in by this guide or those before it")
                    report.add(check, guide, n, qid,
                               f"{label}: prerequisite {names} {said} (for {len(who)} of {len(chars)} characters)")

        if hands_in(step):
            for c in chars:
                done[c].add(qid)
    return done


def check_chains(guides, game, report):
    by_name = {}
    for g in guides:
        if g["name"] in by_name:
            report.add("guide-duplicate", g, None, None, f'"{g["name"]}" is also {by_name[g["name"]]["rel"]}')
        by_name.setdefault(g["name"], g)
    leading = defaultdict(list)  # guide name -> the guides whose "next" it is
    for g in guides:
        nxt = g.get("next")
        if not nxt:
            continue
        target = by_name.get(nxt)
        if not target:
            report.add("next-dangling", g, None, None, f'next guide "{nxt}" does not exist')
            continue
        leading[nxt].append(g)
        a, b = (g.get("fromLevel"), g.get("toLevel")), (target.get("fromLevel"), target.get("toLevel"))
        if None not in a + b and (b[0] > a[1] or b[1] < a[0]):
            report.add("next-gap", g, None, None,
                       f'levels {a[0]}-{a[1]}, but next guide "{nxt}" is for {b[0]}-{b[1]}')
        seen, at = {g["name"]}, target
        while at and at.get("next"):
            if at["next"] == g["name"]:
                report.add("next-cycle", g, None, None, f'its "next" chain comes back to it (through "{at["name"]}")')
                break
            if at["next"] in seen:
                break
            seen.add(at["next"])
            at = by_name.get(at["next"])

    # The steps, each guide after the guides leading to it (their quests handed in count as done).
    after, visiting = {}, set()

    def run(g):
        if g["name"] in after:
            return after[g["name"]]
        if g["name"] in visiting:
            return {}
        visiting.add(g["name"])
        before = defaultdict(set)
        for prev in leading.get(g["name"], ()):
            for c, qs in run(prev).items():
                before[c] |= qs
        after[g["name"]] = check_steps(g, game, report, before)
        return after[g["name"]]

    sys.setrecursionlimit(10000)
    for g in guides:
        if by_name[g["name"]] is g:
            run(g)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="*", type=Path, help="guide directories or files (default: the shipped guides)")
    ap.add_argument("--db", type=Path, default=ROOT / "data/forever.sqlite.zst")
    ap.add_argument("--allow", type=Path, default=ROOT / "addon/tools/guide_validate.allow")
    ap.add_argument("-v", "--verbose", action="store_true", help="list every warning")
    args = ap.parse_args()

    guides = load_guides(args.paths or DEFAULT_DIRS)
    report = Report(args.allow)
    # The database is decompressed to a temporary directory, never next to the repository's copy.
    with tempfile.TemporaryDirectory() as tmp:
        dbpath = args.db
        if dbpath.suffix == ".zst":
            if not shutil.which("zstd"):
                sys.exit("guide_validate: zstd is needed to read " + str(args.db))
            dbpath = Path(tmp) / "game.sqlite"
            subprocess.run(["zstd", "-dqf", str(args.db), "-o", str(dbpath)], check=True)
        db = sqlite3.connect(dbpath.resolve().as_uri() + "?mode=ro", uri=True)
        try:
            game = Game(db)
        finally:
            db.close()
    check_chains(guides, game, report)
    print(f"guide_validate: {len(guides)} guides, {sum(len(g['steps']) for g in guides)} steps")
    sys.exit(report.finish(args.verbose))


if __name__ == "__main__":
    main()
