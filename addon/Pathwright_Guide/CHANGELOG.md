# Pathwright Guide

What changes for players in each version of this addon, shown on its CurseForge and Wago pages.
Same rules as the app's CHANGELOG.md: one short line per change, what the player sees. New lines go
under Unreleased; `scripts/release.sh` gives them the release's version.

## Unreleased

- Undead Starter (1-13): the Samuel Fipps step now completes by itself once you have looted his remains. It stays done after you bury them or hand in Marla's Last Wish.
- A quest you take in a party is shared with it at once, so the others need not find the quest giver. Two settings under World map and group:
  - "Share the quests you take with the party": on by default.
  - "Only when the whole party uses Pathwright": on by default, so players without the addon get no quest offers they did not ask for. Unticked, quests are shared with any party.
  - A quest is not offered to members who already have it or took it at the same moment, is not shared back by who receives it, and one taken in a fight is shared after it. `/pw party` says who in your party runs the addon.
- The way to the guide's place is now found in game from where you stand, on the same walkable ground the app plans its walks on: around steep ground and water, over bridges, through caves, and by the lifts of Thunder Bluff, the Undercity and the Great Lift. It is found again when you leave it, and shown on the compass, the world map and the minimap. Before, the guide's walk started at the previous step and was only followed when you were near it. "Route found from where you stand" under Path turns it off; `/pw way` says what it is doing. With Shortest Path Forever linked, that addon still leads.
- Stranglethorn Vale (46-47): the guide no longer asks for the Booty Bay flight path after it has already had you fly there, because you already know it.
- Tauren Starter (1-13): the Palemane Tanner step now points its marker at the Palemane camp south of the Winterhoof well (51.5, 73.5).
- On the step that takes The Ravaged Caravan from Morin Cloudstalker, the world map draws the road he walks as a line, for as long as that step is the one to do.
- Players' shared quest stats whose seal has the top bit set (about half of them) are no longer dropped with "integer overflow attempting to store".
- WoW Forever: the merchant's automatic purchase of food, water and ammo works again, instead of raising an error at every merchant.
- With a UI suite's look (EllesmereUI, ElvUI), the guide's texts that change size are drawn at the right size again: the party line shrinks to fit, and the "mobs on the way" rows and the level marks of the next steps are small as intended.
- You can choose the addon's font: "Addon font" under Display, after the addon's colors. The list is every font your other addons share (through LibSharedMedia, as most addons with a font choice do), and the change shows at once in the guide, the quest panel, the toolstrip, the compass and the leaderboard. Without such an addon, the game's four fonts are offered.
- The toolstrip can be laid out as a list, and from either side, so long names no longer push it off the screen. Five new settings under Toolstrip:
  - "Toolstrip layout": Row (as before: the buttons side by side, a short name under each icon) or List (one button a line, its whole name beside its icon).
  - "Toolstrip side": Left (the icons at the left edge, the names running to the right) or Right (the icons at the right edge, the names running to the left and ending at the icon). The strip is then held over the guide by that corner.
  - "Toolstrip icon size": from 12 to 48 pixels, one pixel at a time.
  - "Toolstrip name length": how many characters of each name are kept, from 0 (no names, the icons alone) to 40.
  - "Toolstrip text size": the size of the names and of the objective progress, from 8 to 20.
- The toolstrip shows the key each button is bound to over its icon, and how far the objective is after the name, such as "Highland Strider (3/10)", kept up to date as you kill and loot, in a fight too. Each can be turned off under Toolstrip: "Key on the toolstrip icons" and "Objective progress on the toolstrip".

- WoW Forever: each character has its own guide again. The characters of one account were kept as a single one (the game gives them the same name, "Weirdman" for both "Weirdman Dan" and "Weirdman Blueback"), so one character opened on another's guide at its step, and they shared their quest scores, bank notes and profile. Each is now told apart by its own number in the game.
  - What was kept so far goes to the character it was last used by (its class and race). Your other characters start on their own: the guide for their level, no scores yet.
- WoW Forever: the leaderboard takes your friends' records. Every record was refused, because a record is sealed with its character's name and the two sides did not name the character the same way (its first word alone on its own game, its whole name on the others'). Records refused so far are asked for again at your next login.

- The built-in guides show the walk to each step on the map and the compass follows its turns, as in the guides made in the app.

- On the flight master's map, a green arrow bobs over the destination the guide's step says to fly to (setting "Arrow on the flight's destination"). With "Take the step's flight automatically" on, the flight is still taken as the map opens: the arrow shows when that is off, or with Shift held to choose by hand. A destination you cannot fly to from there gets no arrow, and the chat says so.
- The toolstrip shows the quest item to use for more quests. It only knew the item the game itself names for a quest, which the game does for some quests only, and on WoW Forever it could not find the quest in the log at all. It now also offers the item the quest hands out when you take it, when you carry it and it can be used.

- A Feedback button: the white speech bubble under the guide, left of the leaderboard's crown (or `/pw feedback`). It asks "What went wrong?" and makes a report of your answer and of the game at that moment, so a guide's mistake can be found without questions.
  - The window shows what is sent with your words: your level, class and race, where you stand, the guide and its step, your quest log with its progress, the addon's and the game's versions. No character or account name is included.
  - With the Pathwright Updater running on your computer, "Reload and send" sends it: the game reloads, the updater picks the report up and opens the issue, and the addon tells you its address at your next login.
  - Without it, the report shows selected: copy it and paste it in a message to @Pathwright on Discord.

- The leaderboard scores quests by new rules. The scores you already have stay in your total as they are; the new rules apply to the quests you hand in from this version on.
  - Which quests count: those with something to count (kills, items, objects to use) and escorts. Deliveries, talks, breadcrumbs and "explore this place" quests score nothing. A quest scores once per character, when you hand it in.
  - Score = (base + speed + luck − deaths) × difficulty, never below 0.
    - Base: 40 + 1 for each kill or item the quest asks.
    - Speed: 60 × par ÷ your time, at most 150. Par is 20 seconds a kill and 15 seconds any other objective.
    - Luck: −40 to +60, the kills your drops took against the kills they take on average. The average comes from the other players' records of the same quest, and from the game data until they hold 20 kills. The guide in use no longer changes any score.
    - Deaths: −15 each, on one quest only: the one whose mob you were fighting, else an escort under way, else the quest you last made progress on nearby.
    - Difficulty: the quest's color for your level when its objectives complete. Red ×1.5, orange ×1.25, yellow ×1, green ×0.75, gray ×0.5.
  - Time: a quest's clock starts with the fight of its first kill, for an item quest the first kill of a mob that drops the item, not the first drop. It stops when the objectives complete; the walk to hand it in is not timed. When you do several quests in one place, the time before each kill goes to that kill's quest.
  - Bought items: a unit you looted yourself counts in full. A unit you bought, traded or got by mail counts for half the base when the item also drops in the world, and brings no speed or luck (buy 9 of 10 and a tenth of the speed and luck points is left). An item nothing drops (crafted, sold by a vendor) scores as before. What you loot before taking a quest counts as looted.
  - Escorts: a flat 100 × difficulty, less 15 for each death and each failed attempt.
  - Abandoning a quest and taking it again no longer starts it over: the time, kills and deaths of every attempt add up.
  - Your total is kept forever (the limit of 2000 quests is gone).
- A new leaderboard window (/pw board or the crown under the guide).
  - Two tabs, Friends and Guild. Each player's row shows their class color, total, quests, average, and a bar of what their average quest is made of: base, speed, luck, and what deaths or bad luck cost.
  - Beside the list, the detail of one player: the parts of their average quest, the colors of their quests, and their latest quests with time, luck and points. It opens on you; click a player to see theirs.
  - Drag the corner at the bottom right to make the window taller (more players) or wider, and the line between the list and the detail to give one more room than the other. The mouse wheel scrolls the list and the quests.
  - Scores from before the new rules show as a gray part of the bars, since what they were made of is not known.
- The leaderboard is shared with your guild as well as your friends and your party (setting "Share my scores with my friends and guild").
- Keeping scores honest: what is shared is each quest's facts (kills, drops, time, deaths, levels), and every player's addon works the score out itself.
  - The first record a player sends for a quest stays; a different one for the same quest is refused and the player's name turns red on the board.
  - A record that cannot be (30 kills in 2 seconds) is refused.
  - Each record is sealed with its facts and its character's name: edited by hand in the saved file, it no longer matches and is left out.
  - This stops edited and impossible records. It cannot stop someone who writes code to fake records from the start: only the game server knows what really happened.

- WoW Forever: the sword buttons (a mob to kill) target the nearest mob of their name that no other player has tagged, and are never disabled. Out of combat, just before it fires, a press decides from your target and the mob nameplates on screen:
  - Your target is already an untagged mob of that name: it stays your target and gets the skull and the Attack ping. To pick the mob yourself, click it, then press the sword.
  - The nearest mob of that name is untagged: the press targets it by name, with the skull and the ping.
  - The nearest one is tagged by another player: the press targets it by name, then Tabs once (`/targetenemy`) to the next nearest enemy.
  - The skull and the ping only go on when Pathwright is sure the press ends on an untagged mob of that name. Otherwise you get the target alone, so a tagged or wrong mob is never marked or pinged.
  - With "Aim at a mob no other player has tagged" off, tagged mobs count as any other.
- Why it works this way: what WoW Forever lets an addon do.
  - A button can only target a mob by its name, and the game then takes the nearest one of that name. Pressing again doesn't move on to the next: it stays on the nearest.
  - The game refuses to target a mob through its nameplate (`/target nameplate1`, `[@nameplate1]`), so Pathwright can see the right mob but cannot name that one mob to the game.
  - A button cannot have another button check the target after it is taken: on Forever the hidden checker's `/click` never runs from the sword. The previous version relied on it, which is why tagged mobs were still targeted, marked and pinged.
  - So everything is decided before the press, from the nameplates Pathwright already reads (four times a second): which mobs of that name are tagged, and roughly how far each one is.
- What it cannot know, and what it does then:
  - Distance is coarse: for a hostile mob the game only answers whether it is within about 10 yards, about 28 yards, or the range of one of your attack spells. Two mobs in the same band count as equally near; the press then targets by name without the skull and the ping instead of guessing.
  - Tab follows the game's own order: when another enemy is as near as the untagged mob, Tab may land on it, so there is no skull or ping.
  - Mobs with no nameplate on screen (behind you, out of nameplate range, nameplates off) can't be seen: the press takes the nearest by name.
  - In combat the game locks every button: the sword targets the nearest by name, with the skull and the ping, without these checks.

- The guide pickers group routes into Imported, Default and RestedXP. Each section remembers its name search, level range and character filter while you browse.

- The toolstrip docks above the guide. Enable “Unlock the toolstrip” to drag it by its left edge.
- Smaller toolstrip icons show short names underneath to distinguish targets at a glance.
- WoW Forever: with Shortest Path Forever installed, the compass and the arrow follow the route it plans to the step (the next turn of the walk, the flight master, the dock), even when the step is on another continent; the guide's own walk shows again whenever it is not guiding.

## 0.21.0 (2026-11-16)

- WoW Forever: a click on a quest in the quest panel makes the game track it, as from the game's own tracker, and a click on the step already shown sets the game's waypoint again.
- WoW Forever: the items a quest needs are bought at the merchant, as on Classic and TBC, and the low health alert in combat and the items to keep at login no longer run into errors.

## 0.20.0 (2026-11-13)

- Escort and event quests are never accepted automatically, nor joined when a party member starts them: in a group, everyone has time to turn in the quest before.

## 0.19.0 (2026-11-12)

- Steps show how their quest is taken or their objective done, and a yellow, orange or red mark when a note tells more about the quest; the step's tooltip lists the notes.
- A quest handed in far ahead of the guide no longer marks the merchants, trainers and flight masters before it as visited.

## 0.18.0 (2026-11-10)

- No more blocked-action errors from the quest panel during a fight; its layout catches up afterwards.
- Guides pasted on Windows no longer fail to import on large numbers.

## 0.17.0 (2026-11-09)

- An objective guide done below the level its quests ask says so on the current step until you reach it.
- World map pins and the walk's dots keep their size on a map enlarged by another addon.

## 0.16.0 (2026-11-07)

- WoW Forever: no more "ADDON_ACTION_BLOCKED: SetPassThroughButtons" message when the world map is open during a fight.
- A dungeon's quests show together until each is done, even after leaving it; "Skip the dungeon" leaves the ones not finished aside.
- WoW Forever: the Sleeping Bag XP reminder starts after its reward quest is completed.

## 0.15.0 (2026-11-01)

- Two flights in a row: taking the first no longer counts the next one as done; each is done by its own take-off.
- Group guides: quest XP counts each player's own reward, including its Sleeping Bag bonus.
- WoW Forever: a guide made with the food or Sleeping Bag XP bonus warns when that buff is missing (out of combat, at most every ten minutes).
- Logging in (or reloading) puts the guide back on the step you were on, instead of the first step the game cannot tell is done (GitHub #81).
- The addon's separators are a bullet (•), which every client font has: the dot they used was a missing glyph in Russian (GitHub #78).
- Death skip steps: done once back at the spirit healer.
- A quest that needs a number of other quests done (ten library books) is offered once enough of them are.
- Group guides: each player follows its own profession curve.
- Group guides made for characters the app had no profile of: the addon finds yours by race and class; when several match, choose yours in /pw, Guides ("Player: …").
- The wind guide (a gust of wind towards the step instead of the compass) is gone, with its settings and key binding; the compass stays.
- Objectives done in the same area (mobs next to each other) are shown together in Now, and a level checkpoint between them no longer cuts them apart: it comes after them (GitHub #41).
- Merchant, trainer, flight master and inn steps before the last quest you handed in are done on their own when a guide is loaded or reset, instead of each needing a right click.

## 0.14.0 (2026-10-20)

- The guide's XP bars show a hollow gold box over the XP the current steps give, from where the guide expects you before them to after them.
- In the game's addon list, the Pathwright addons are under Quests, with their own icon, Guide and Data grouped under Profile.
- The full and minimal guides each keep their own layout: moving or resizing the quest panel or the compass in one mode no longer changes the other.
- No mark on the game's XP bar any more, and the game's XP tooltip is back: the guide's own XP bar shows where you should be (GitHub #36).
- A step to sell your loot at a vendor on the way, ticked when the merchant's window opens.
- A kind of step this version does not know yet (a guide from a newer app) is shown and passed on its own.

## 0.13.0 (2026-10-19)

- First version on CurseForge and Wago: the guide made in the Pathwright app, its compass, quest automation and fast loot. Needs Pathwright Profile.
