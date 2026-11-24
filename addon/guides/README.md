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

## Walks

Each step also gets the walk to it from the step before (`wp`, world coordinates, as in an app
guide), planned by the app's pathfinding: `guide_build.py` sends the legs of every variant to
`fg guide-walks` (through `cargo run --release -p fg`, or the binary given by `--fg <path>` or
`FG_BIN`). A step whose walk differs between variants keeps the most common one in `wp` and the
others in `wv`, which `Builtin.Expand` resolves for the character. After a flight the walk starts
at the flight master it lands at, after the hearthstone at the inn. No walk leads to a hearthstone
or to a step whose text says to fly or take a zeppelin, boat or portal, and none follows a note
that says so (it has no place to start from). A failing `fg` stops the build; `--no-walks` builds
without walks.

    scripts/build-builtin-guides.sh                 # every guide, fg built once
    scripts/build-builtin-guides.sh addon/guides/skyborne_starter.guide --out /tmp/x

`scripts/addon-test.sh` checks that every shipped guide has its walks.

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
