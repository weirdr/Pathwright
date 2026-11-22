# Built-in guides

The guides that ship with the addon, written by us. Each `*.guide` file is a guide script: the
order of the steps (take, do and hand in quests, train, sell, set the hearthstone), in our own
words. `addon/tools/guide_build.py` (its docstring lists the script lines) fills in the rest from
the game data, `data/forever.sqlite.zst`: who gives and takes each quest and where they stand,
what each objective needs and where its mobs or objects are, who drops its items, levels and
prerequisites, which races and classes each quest is for.

    python3 addon/tools/guide_build.py addon/guides/skyborne_starter.guide

writes `addon/Pathwright_Guide/Builtin/SkyborneStarter.lua`; `scripts/install-addon.sh` installs
the folder with an index the addon loads. The addon offers each guide to the characters it has a
variant for (`Builtin.lua`).

## Writing a guide

1. List the zone's quests from the game data (`m_quest` by `zone_or_sort`, plus the quests whose
   givers or turn-ins spawn there) and check the list against a quest database such as
   outof.games (`/realms/forever/quests/zone/<area id>-<zone>/`); read the quest pages for
   anything the data leaves unclear (prerequisites, who can take it, where an item comes from).
2. Group the quests by hub and by the area their objectives are in, and write the route.
3. Build it, then compare it with another guide for the zone, such as Zygor's, as a check:
   `luajit addon/tools/zygor_convert.lua <Zygor guide file> "<title>"` writes a reference copy in
   `debug/zygor` (never shipped), and `luajit addon/tools/guide_compare.lua <ours> <reference>`
   lists the quests one has and not the other and the steps whose place or NPC differ.
