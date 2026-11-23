#!/usr/bin/env python3
"""Check a chain of built-in guides (linked by `next`) and set their `carry` and `leave` lines.

    python3 -I addon/tools/guide_chain.py ["<first guide name>" ...] [--write]

Without names: every guide no other guide names as its `next` starts a chain. It exits with 1
when it finds a problem.

Several first guides (the starters of each race) may lead into the same chain: each chain is
worked out, and a guide they share carries and leaves what any of them needs.

A quest taken in one guide and handed in by a later one (a breadcrumb into the next zones) is left
by the guide that takes it, carried and left again by each guide in between, and carried by the
one that hands it in. This tool works that out from the guides' accept and turnin lines and,
with --write, rewrites the `carry`/`leave` lines of each guide (its other lines stay as they are).
Quests a guide carries that no guide of the chain takes (taken before the chain) stay carried.

It also reports, across the chain:
- a quest taken by two guides;
- a quest taken and never handed in;
- a quest handed in by a guide that neither takes nor carries it.
"""
import glob, os, re, sys

firsts = [a for a in sys.argv[1:] if not a.startswith("--")]
write = "--write" in sys.argv

guides = {}
for path in glob.glob("addon/guides/*.guide"):
    g = {"path": path, "name": None, "next": None, "accept": [], "turnin": [], "do": [], "carry": set(), "leave": set()}
    for line in open(path, encoding="utf-8"):
        t = line.split(" #")[0].strip()
        if t.startswith("#") or not t:
            continue
        word, _, rest = t.partition(" ")
        ids = []
        for w in rest.split():
            if re.match(r"^\d+(\.\d+)?$", w):
                ids.append(int(w.split(".")[0]))
            else:
                break
        if word == "guide":
            g["name"] = rest.strip()
        elif word == "next":
            g["next"] = rest.strip()
        elif word in ("accept", "turnin", "do"):
            g[word] += ids
        elif word in ("carry", "leave"):
            g[word].update(int(w) for w in rest.split())
    if g["name"]:
        guides[g["name"]] = g

problems = []
wants = {}


def work(first):
    chain, name = [], first
    while name:
        if name not in guides:
            print(f"missing guide: {name}")
            break
        chain.append(guides[name])
        name = guides[name]["next"]
    print(f"{first}: {len(chain)} guides in the chain")

    taken_in, handed_in = {}, {}
    for i, g in enumerate(chain):
        for q in g["accept"]:
            if q in taken_in and taken_in[q] != i:
                problems.append(f"quest {q} taken by {chain[taken_in[q]]['name']} and {g['name']}")
            taken_in.setdefault(q, i)
        for q in g["turnin"]:
            if q in handed_in and handed_in[q] != i:
                problems.append(f"quest {q} handed in by {chain[handed_in[q]]['name']} and {g['name']}")
            handed_in.setdefault(q, i)

    want = [{"carry": set(), "leave": set()} for _ in chain]
    for q, i in taken_in.items():
        j = handed_in.get(q)
        if j is None:
            problems.append(f"quest {q} taken by {chain[i]['name']} and handed in by no guide")
            continue
        if j < i:
            problems.append(f"quest {q} handed in by {chain[j]['name']} before {chain[i]['name']} takes it")
            continue
        if j > i:
            want[i]["leave"].add(q)
            for k in range(i + 1, j):
                want[k]["carry"].add(q)
                want[k]["leave"].add(q)
            want[j]["carry"].add(q)
    # Taken before the chain (its first guides say so with `carry`): carried from the first guide
    # that uses it (does its objectives, hands it in, or carries it) to the one that hands it in.
    first_use = {}
    for j, g in enumerate(chain):
        for q in set(g["turnin"]) | set(g["do"]) | g["carry"]:
            if q not in taken_in:
                first_use.setdefault(q, j)
    for q, i in first_use.items():
        j = handed_in.get(q)
        if j is None:
            if any(q in g["carry"] for g in chain):
                # Handed in after the chain's end: carried through to it.
                j = len(chain)
            else:
                problems.append(f"quest {q} used by {chain[i]['name']} but neither taken nor carried")
                continue
        if j < i:
            continue
        for k in range(i, min(j, len(chain) - 1) + 1):
            if k < len(chain):
                want[k]["carry"].add(q)
                if k < j:
                    want[k]["leave"].add(q)


    for g, w in zip(chain, want):
        acc = wants.setdefault(g["name"], {"carry": set(), "leave": set(), "g": g})
        acc["carry"] |= w["carry"]
        acc["leave"] |= w["leave"]


if not firsts:
    named = {g["next"] for g in guides.values() if g["next"]}
    firsts = sorted(n for n in guides if n not in named)
for f in firsts:
    work(f)
for name, w in wants.items():
    g = w["g"]
    if (w["carry"], w["leave"]) != (g["carry"], g["leave"]):
        print(f"{g['name']}: carry {sorted(w['carry'])} (was {sorted(g['carry'])}), "
              f"leave {sorted(w['leave'])} (was {sorted(g['leave'])})")
        if write:
            lines = open(g["path"], encoding="utf-8").read().split("\n")
            out, placed = [], False
            for line in lines:
                if re.match(r"^(carry|leave)\b", line.strip()):
                    continue
                out.append(line)
                if not placed and re.match(r"^levels\s", line.strip()):
                    placed = True
                    if w["carry"]:
                        out.append("carry " + " ".join(str(q) for q in sorted(w["carry"])))
                    if w["leave"]:
                        out.append("leave " + " ".join(str(q) for q in sorted(w["leave"])))
            open(g["path"], "w", encoding="utf-8").write("\n".join(out))
for p in sorted(set(problems)):
    print("problem:", p)
if problems:
    sys.exit(1)
