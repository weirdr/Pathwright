#!/usr/bin/env python3
"""Quest items worth buying at the auction house instead of farming them, for a guide's quests.

    python3 -I addon/tools/guide_ah.py data/forever.sqlite <quest id> [...]

For each item a quest asks to collect: whether it can be traded (not a quest item), how it drops
(the best drop rate, and from how many kinds of mobs or objects), and whether it sells at the
auction house: the realm's auctions and prices from TSM's AppHelper data (synced by the TSM desktop
app), or a region price. Verdict "ah": worth offering an `ah` step (tradeable, sold, slow to farm:
a low drop rate, many to get, or made by a craft or skinned); "ah?": sold but quick to farm here;
"-": not seen at the auction house; "quest item": cannot be traded.
"""
import os, re, sqlite3, sys

DB = sqlite3.connect(sys.argv[1])
one = lambda sql, *a: DB.execute(sql, a).fetchone()
rows = lambda sql, *a: DB.execute(sql, a).fetchall()
TSM = os.path.expanduser(
    "/Applications/World of Warcraft/_forever_/Interface/AddOns/TradeSkillMaster_AppHelper/AppData.lua")


def b32(s):
    return int(s, 32) if s else 0


def money(c):
    return f"{c // 10000}g{c // 100 % 100:02d}s{c % 100:02d}c" if c else "-"


realm, region = {}, set()
if os.path.exists(TSM):
    text = open(TSM, encoding="utf-8", errors="replace").read()
    for tag, body in re.findall(r'LoadData\("([A-Z_]+)","[^"]*",\[\[return (.*?)\]\]\)', text, flags=re.S):
        fields = re.search(r"fields=\{([^}]*)\}", body)
        fields = [f.strip('"') for f in fields.group(1).split(",")] if fields else []
        for rec in re.findall(r"\{(\d+),([^{}]*)\}", body):
            item = int(rec[0])
            vals = rec[1].split(",")
            if tag == "AUCTIONDB_NON_COMMODITY_DATA":
                v = dict(zip(fields[1:], vals))
                realm[item] = (b32(v.get("minBuyout")), b32(v.get("numAuctions")))
            elif tag.startswith("AUCTIONDB_"):
                region.add(item)

print(f"{'quest':>6} {'item':>7} {'need':>4}  {'best drop':>9} {'sources':>7}  {'realm min':>12} {'listed':>6}  verdict  name")
for qs in sys.argv[2:]:
    q = int(qs)
    for idx, typ, item, amount in rows(
            "select idx, type, target_id, amount from m_quest_objective where quest_id=? and type='item'", q):
        it = one("select name, class from m_item where id=?", item)
        name, cls = (it or (f"item {item}", None))
        need = int(amount or 1)
        src = rows("select from_type, chance from m_item_source where item_id=? and from_type in ('npc','object')", item)
        best = max((float(c or 0) for _, c in src), default=0)
        minb, listed = realm.get(item, (0, 0))
        sold = item in realm or item in region
        # Class 12 (quest) items mostly cannot be traded, but some common ones are sold all the same:
        # being on the auction house proves it.
        tradeable = cls != 12 or sold
        # Slow to farm: a low drop rate, many to get, or no drop at all here (made by a craft, skinned,
        # or dropping from everything: a trade good).
        slow = not src or best < 0.25 or need / max(best, 0.01) > 20 or len(src) > 40
        verdict = ("quest item" if not tradeable else "-" if not sold else "ah" if slow else "ah?")
        print(f"{q:>6} {item:>7} {need:>4}  {best:>9.0%} {len(src):>7}  {money(minb):>12} {listed:>6}  {verdict:<7}  {name}")
