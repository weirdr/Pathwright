# Horde guides 40-60: what is in them (November 2026)

24 built-in guides, Riverglades (40-41) to Silithus (59-60), chained with `next`: each one opens the
following when it ends. They are written for a Horde duo, so elite and WANTED quests are in. Every
quest taken is handed in within the guide. The only exceptions are breadcrumbs into later zones,
which `addon/tools/guide_chain.py` carries from guide to guide until the one that hands them in.

How they were made:
- `addon/guides/horde_40_60_allocation.md` says which guide owns each quest (built from Zygor's
  guides plus every quest Zygor skips, from the game data).
- Each guide was researched from the game data and outof.games, then compared with Zygor's.
- The checks: 0 build errors, 0 warnings, and all 28 Horde race and class routes pass the addon's
  tests.

| # | Guide | Quests | Dropped (why) | Added | Auction house |
|---|---|---|---|---|---|
| 1 | Riverglades (40-41) | 49 | Key Ingredients (its moulding drops only in the Krol'dok dungeon) | | Heavy Weightstone (Undercity) |
| 2 | Stranglethorn Vale & Swamp of Sorrows (41-43) | 46 | Drowned City quests (dungeon), 96078, 638, 670, 2932, 97332 (handed in off the route) | | |
| 3 | Desolace & Shen'dralas (43-43) | 31 | 29: the Gelkis Valley of Bones chain behind Ongeku (shard in the Swamp of Sorrows), the Magram chain (crown from the Badlands), 79235/79236/79242, 93678, 93601, 93606 (dungeon prerequisites) | 5381, 1368, 1370 (prerequisites) | Barbaric Harness (note) |
| 4 | Tanaris (43-43) | 14 | | | |
| 5 | Dustwallow Marsh (43-44) | 12 | | | |
| 6 | Tanaris (44-44) | 6 | | 2876 Ship Schedules | |
| 7 | Riverglades (44-45) | 38 | 94975, 94972, 94968 (Krol'dok dungeon) | | Briny Seafood Stew (Undercity) |
| 8 | Feralas (45-46) | 28 | | 92878 Lost for Words | |
| 9 | Stranglethorn Vale (46-47) | 38 | 78823 (drawing only in the Badlands) | 583, 349 | the 15 Green Hills pages (Orgrimmar) |
| 10 | Swamp of Sorrows (47-47) | 13 | | | |
| 11 | Tanaris & Dustwallow Marsh (47-48) | 42 | Zul'Farrak and Uldaman chains (2865, 3042, 2768, 3527, 2846, 2954, 2967), 4787; the egg quests as a note | | |
| 12 | The Hinterlands (48-49) | 39 | 3 battleground quests, 4787 | 7846 Recover the Key! | Long Elegant Feather (Undercity) |
| 13 | Feralas & Un'Goro Crater (49-50) | 24 | 7 Maraudon quests (dungeon), 7738 (skinners only) | | Red and Yellow Power Crystals (Orgrimmar) |
| 14 | Stranglethorn Vale & Swamp of Sorrows (50-50) | 19 | 626 Cortello's Riddle (treasure in the Hinterlands, not revisited) | | Document Box (costs more than the quest pays) |
| 15 | Blasted Lands (50-51) | 7 | 87295 (giver inside Nethergarde Keep), 2521 (not in Forever), 81917 | 87451 Memories of Rockard | gizzards, brains, fragments (Orgrimmar) |
| 16 | Searing Gorge (51-51) | 19 | 81900 (handed in in the Blasted Lands, not revisited) | | Silk Cloth (Orgrimmar) |
| 17 | Burning Steppes & Azshara (51-52) | 36 | Blackrock Depths quests (3802, 4136, 4123), 98096 (Alliance), the Undercity/Thunder Bluff copies of 91735 | | Winter Squid (Orgrimmar) |
| 18 | Felwood & Winterspring (52-53) | 18 | | | |
| 19 | Un'Goro Crater (53-54) | 35 | 4146/4148 (Sunken Temple drop), 3962 (needs guide 23's 3961), 92020 (Mount Hyjal) | | Mithril Casing, Un'Goro Soil (Orgrimmar) |
| 20 | Azshara (54-54) | 17 | 3506 (gone in WoW Forever), 3141, 92066 (dungeon), 91877 (Hyjal), 6804/6805 | | |
| 21 | Felwood & Winterspring (54-56) | 64 | 626, 7816 (Hinterlands), 3507, 8467, 90647 | 8 Hyjal quests the chains need | |
| 22 | Western & Eastern Plaguelands (56-58) | 100 | 42: Scholomance, Stratholme, Blackrock Spire and Naxxramas chains, Argent Dawn Revered/Exalted rewards, Alliance-camp givers | 7790, 8152 | Smokey's parts, the cloth donations (Undercity, Orgrimmar) |
| 23 | Winterspring (58-59) | 36 | 4907, 5161/5162 (Blackrock Spire), 84146, 84212, 5163 (handed in at Everlook after leaving it) | | the cloth donations (Orgrimmar) |
| 24 | Silithus (59-60) | 35 | Ahn'Qiraj, Blackwing Lair and raid quests (8315, 8301-8305, 8519, 8743, 8745, 9023, 8352, 9248), Revered quests (8343, 8341, 8351) | | |

"Quests" counts every quest a guide has a step for, including breadcrumbs it carries.

## For the players to decide

- **Desolace:** an extra trip (take Ongeku in Desolace, kill Ongeku in the Swamp of Sorrows, come
  back) would bring back about 13 Gelkis quests. Picking the Magram side instead would need a crown
  from a Badlands crypt.
- **Winterspring (58-59):** goes back to the Eastern Kingdoms (Undercity, Flame Crest) for two quests
  (4810, 84399), about 15 minutes. These can be cut.
- **Silithus:** the Aurel Goldleaf chain needs Friendly with the Cenarion Circle; the guide gets close,
  and a tip covers the gap. Natalia and the Duke are level 62 elites.
- **Felwood & Winterspring (54-56):** The Videre Elixir (3909) needs the elixir from a quest that is
  not in the game client (4041). Its step points at Gregan in Feralas as a fallback.

## Known data problems

- Most Eastern Plaguelands spawns from Wowhead use an older map: about x*1.109+1.73,
  y*1.095+4.6 of today's coordinates. The Plaguelands guide pins its steps by hand.
- The builder does not read objective places stored in `m_quest_objective.extra` (triggers): such
  steps take `at`.
