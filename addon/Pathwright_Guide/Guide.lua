-- Follows the planned route and advances automatically. What it shows (see Guide:Refresh):
--   the current tasks (steps done at the same place are grouped), with progress, and the mobs to
--   kill on the way to them, counted;
--   the next steps, or the next quests that can be taken now with their distance (close quests
--   can be taken in any order, the route skips them once in the log).
-- Drawn by Card.lua (full) or Mini.lua (minimal); the compass (Compass.lua) and the native
-- waypoint point at the first unfinished task.

local FG = Pathwright
local T = FG.T
local QuestLog = FG.QuestLog
local Guide = {}
FG.Guide = Guide

local L = {
    recommended = T("Level %d recommended, you are %d"),
    needsLevel = T("Level %d needed to take this quest, you are %d: do the next steps and come back"),
    todo = T("To do"),
    next = T("Next"),
    pickup = T("To pick up"),
    farmXP = T("%s/%s XP"),
    farmXPPlanned = T("~%s XP"),
    farmTip = T(
        "XP to earn from the mobs killed on the way to this step (since it became current). The mobs of a quest objective not finished yet do not count."
    ),
    pointHint = T("Left-click: the compass points at this step"),
    level = T("Lvl"),
    planned = T("planned"),
    noRoute = T("No guide chosen for this character.\nType /pw and click Follow beside a guide."),
    noGuides = T("No guide yet.\nMake one in the Pathwright web app, then type /pw and click Import a guide…"),
    done = T("Route finished!"),
    nextGuide = T("guide finished: on to %s"),
    yards = T("yd"),
    prevStep = T("Previous step"),
    nextStep = T("Next step"),
    settings = T("Addon settings"),
    resync = T("Start over: undo the steps and quests marked done by hand, then go to the first step not done yet"),
    resetConfirm = T(
        "Undo the steps and quests marked as done by hand (%d) and go back to the first step not done yet?"
    ),
    resetDone = T("guide started over: marks by hand undone"),
    ahead = T("Ahead: skip to the level %d checkpoint (%d steps)"),
    aheadTip = T(
        "You reached this checkpoint's level earlier than planned: the steps up to it are skipped, except chains going on after it, class quests, planned rewards and training."
    ),
    alongTheWay = T("along the way"),
    partyWaits = T("done, waiting for %s"),
    elite = T("elite"),
    skipHint = T("Right-click: mark as already done (or undo)"),
    skipped = T("quest marked as done: %s (to undo: the “Undo the last mark” key)"),
    unskipped = T("quest to do again: %s"),
    stepSkipped = T("step marked as done"),
    dungeonSkipped = T("dungeon left aside: %s (%d steps; to undo: the “Undo the last mark” key)"),
    dungeonLeft = T("%s: %d steps left"),
    skipDungeon = T("Skip the dungeon"),
    dungeonTip = T("Mark the dungeon's steps not done as done: its quests not finished are left aside."),
    stepUnskipped = T("step to do again"),
    spot = T("spot %d/%d (next: the “Next spot” key)"),
    noSpot = T("this step has no other spot"),
}

local KINDS = {
    accept = {
        icon = "Interface\\GossipFrame\\AvailableQuestIcon",
        color = "ffd100",
        label = T("Accept"),
    },
    turnin = {
        icon = "Interface\\GossipFrame\\ActiveQuestIcon",
        color = "40ff40",
        label = T("Turn in"),
    },
    -- The ready check's red cross (in the Forever, Classic Era and TBC clients alike).
    abandon = {
        icon = "Interface\\RaidFrame\\ReadyCheck-NotReady",
        color = "ff4040",
        label = T("Abandon"),
    },
    objective = { icon = "Interface\\Icons\\Ability_DualWield", color = "ff9040", label = T("Do") },
    fly = { icon = "Interface\\GossipFrame\\TaxiGossipIcon", color = "40c0ff", label = T("Fly") },
    flight_master = {
        icon = "Interface\\GossipFrame\\TaxiGossipIcon",
        color = "40c0ff",
        label = T("Flight path"),
    },
    link = { icon = "Interface\\Icons\\INV_Misc_Map_01", color = "40c0ff", label = "Transport" },
    grind = { icon = "Interface\\Icons\\Ability_Rogue_Ambush", color = "c080ff", label = T("Grind") },
    train = { icon = "Interface\\Icons\\INV_Misc_Book_09", color = "ffffff", label = T("Trainer") },
    hearth = {
        icon = "Interface\\Icons\\INV_Misc_Rune_01",
        color = "40c0ff",
        label = T("Hearthstone"),
    },
    teleport = {
        icon = "Interface\\Icons\\Spell_Arcane_TeleportStormWind",
        color = "40c0ff",
        label = T("Teleport"),
    },
    deathskip = { icon = "Interface\\Icons\\Spell_Holy_Resurrection", color = "c0c0ff", label = T("Death skip") },
    bind = { icon = "Interface\\GossipFrame\\BinderGossipIcon", color = "40c0ff", label = T("Inn") },
    sell = { icon = "Interface\\GossipFrame\\VendorGossipIcon", color = "ffffff", label = T("Vendor") },
    -- The built-in guides' own: a place to reach, something to read and mark done.
    ["goto"] = { icon = "Interface\\Icons\\INV_Misc_Map_01", color = "40c0ff", label = T("Go to") },
    note = { icon = "Interface\\Icons\\INV_Misc_Note_01", color = "ffffff", label = T("Note") },
    dungeon = { icon = "Interface\\Icons\\INV_Misc_Key_10", color = "ff4040", label = T("Dungeon") },
    profession = {
        icon = "Interface\\Icons\\Trade_BlackSmithing",
        color = "e0b050",
        label = T("Profession"),
    },
    practice = {
        icon = "Interface\\Icons\\INV_Misc_Note_01",
        color = "e0b050",
        label = T("Practice"),
    },
}
-- A step of a kind this addon does not know (made by a newer app): its text, done right away.
local OTHER = { icon = "Interface\\GossipFrame\\GossipGossipIcon", color = "ffffff", label = T("Step") }

-- How a quest is taken or an objective done (the step's `ic`, from the app): its icon instead of
-- its kind's. Textures of the Forever, Classic Era and TBC clients alike; "npc" keeps the kind's.
local ICONS = {
    object = "Interface\\Icons\\INV_Box_01",
    item = "Interface\\Icons\\INV_Scroll_03",
    item_drop = "Interface\\Icons\\INV_Misc_Bag_09",
    kill = "Interface\\Icons\\Ability_DualWield",
    elite = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull",
    get = "Interface\\Icons\\INV_Misc_Bag_08",
    use = "Interface\\Icons\\INV_Misc_Gear_01",
    talk = "Interface\\GossipFrame\\GossipGossipIcon",
    buy = "Interface\\GossipFrame\\VendorGossipIcon",
    text = "Interface\\Icons\\INV_Misc_Spyglass_03",
    rare = "Interface\\Icons\\Ability_Hunter_SniperShot",
    event = "Interface\\Icons\\INV_Misc_PocketWatch_01",
    pickup = "Interface\\Icons\\INV_Crate_02",
}

-- Quest notes (the step's `nt`: { l = 1-3, t = text }): a mark after the step's name, yellow
-- (good to know), orange (watch for it) or red (must read), the notes in the step's tooltip.
local NOTE_TEXTURE = "Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew"
local NOTE_TINT = { { 255, 255, 255 }, { 255, 140, 60 }, { 255, 40, 40 } }
local NOTE_COLOR = { { 1, 0.82, 0 }, { 1, 0.55, 0.15 }, { 1, 0.25, 0.25 } }

--- The icon of a step: how it is done when the app says, else its kind's.
local function StepIcon(step, kind) return (step.ic and ICONS[step.ic]) or kind.icon end

--- The highest level of a step's notes, nil without notes.
local function NoteLevel(step)
    local top
    for _, n in ipairs(step.nt or {}) do
        local l = math.max(1, math.min(3, tonumber(n.l) or 1))
        if not top or l > top then top = l end
    end
    return top
end

--- The mark of a step's notes to put after its name (" " and an inline texture), "" without notes.
local function NoteMark(step, size)
    local level = NoteLevel(step)
    if not level then return "" end
    local c = NOTE_TINT[level]
    size = size or 14
    return string.format(" |T%s:%d:%d:0:0:64:64:0:64:0:64:%d:%d:%d|t", NOTE_TEXTURE, size, size, c[1], c[2], c[3])
end

-- Steps of a group at most (checkpoints apart).
local GROUP_MAX = 6
-- Steps ahead looked at for the quests to pick up.
local PICKUP_AHEAD = 300
-- Steps planned this many levels below the character are skipped.
local OUTDATED_LEVELS = 4
--- Yards from a "goto" step's place where it is reached, when the step gives none.
local GOTO_RADIUS = 20

local state -- per character: { route = name, step = n, point = {...}, flightLearned = id }
local route
local acceptIndex = {} -- quest -> index of its accept step
local turninIndex = {} -- quest -> index of its turn-in step
local plannedBefore = {} -- quest -> true: taken by a built-in guide that leads to this one

--- An objective guide (a dungeon's, a zone's, quests chosen): no level to reach. Those made before
--- `levelsIgnored` was exported end at the level they start at, unlike a leveling guide.
local function ObjectiveGuide()
    return route ~= nil
        and (route.levelsIgnored == true or (route.fromLevel ~= nil and route.fromLevel == route.toLevel))
end
local objectiveQuests = {} -- quests with an objective step
local questMobs = {} -- creature -> indexes of the objective steps done on it (killed, or dropping an item)
local childQuests = {} -- child quests handed in on the way to their parent's turn-in
-- Whether the shown step was already done when we arrived on it (manual navigation): the
-- guide only moves on when the shown step becomes done.
local arrivedDone = false
local waypointStep
-- Step picked by hand (left-click on a row): the compass points at it until it is done.
local pointed
-- Place picked on the compass (a trainer, a flight master...): pointed at until reached.
local detour
local DETOUR_ARRIVED = 10
-- The last step or quest marked as done by hand, for the session: { route, q } or { route, index }.
local lastMark
local Distance -- defined below, used by IsDone

-- Progress -------------------------------------------------------------------

local function QuestTitle(step) return step.q and QuestLog.GetTitleForQuestID(step.q) or nil end

--- Game objective matching the step's target name. When several hold the name ("Night Web
--- Spider slain" and "Young Night Web Spider slain"), the one with the least else around it
--- (counts, spaces and punctuation aside), then the one at the step's objective index.
--- The step's objective in the log and its index there (the party's counts are by index).
local function FindObjectiveIndex(step)
    local objectives = QuestLog.GetQuestObjectives(step.q)
    if not objectives then return nil end
    if not step.n then
        if #objectives == 1 then return objectives[1], 1 end
        if step.o and objectives[step.o] then return objectives[step.o], step.o end
        return nil
    end
    local name = step.n:lower()
    local best, bestIndex, bestRest
    for i, o in ipairs(objectives) do
        local text = o.text and o.text:lower()
        local at = text and text:find(name, 1, true)
        if at then
            local rest = #((text:sub(1, at - 1) .. text:sub(at + #name)):gsub("[%d%p%s]", ""))
            if not best or rest < bestRest or (rest == bestRest and i == step.o) then
                best, bestIndex, bestRest = o, i, rest
            end
        end
    end
    -- No name matched: the step's own index in the quest, when the log has it.
    if not best and step.o and objectives[step.o] then return objectives[step.o], step.o end
    return best, bestIndex
end

local function FindObjective(step)
    local objectives = QuestLog.GetQuestObjectives(step.q)
    if not objectives or not step.n then return nil end
    local name = step.n:lower()
    local best, bestRest
    for i, o in ipairs(objectives) do
        local text = o.text and o.text:lower()
        local at = text and text:find(name, 1, true)
        if at then
            local rest = #((text:sub(1, at - 1) .. text:sub(at + #name)):gsub("[%d%p%s]", ""))
            if not best or rest < bestRest or (rest == bestRest and i == step.o) then
                best, bestRest = o, rest
            end
        end
    end
    return best
end

--- How far a step's objective is, as the quest log counts it: have, need (what the guide shows
--- beside the step). Nil when the step is no counted objective of a quest in the log.
function Guide.Count(step)
    if type(step) ~= "table" or step.k ~= "objective" or not step.q then return nil end
    if not QuestLog.IsOnQuest(step.q) then return nil end
    local o = FindObjective(step)
    local need = o and tonumber(o.numRequired)
    if not need or need <= 0 then return nil end
    return tonumber(o.numFulfilled) or 0, need
end

--- Right after an accept the game lists no objectives (or blank ones) for a moment, while
--- IsComplete may already read true: nothing about the quest's progress can be trusted yet.
local function ObjectivesLoading(q)
    local objectives = QuestLog.GetQuestObjectives(q)
    if not objectives or #objectives == 0 then return true end
    for _, o in ipairs(objectives) do
        if not o.text or o.text == "" then return true end
    end
    return false
end

--- Skill line of a "profession" step (its target is the trainer), from the route professions.
local function ProfessionLine(step)
    if step.line then return step.line end
    for _, p in ipairs(route.professions or {}) do
        if step.t:find(p.name, 1, true) then return p.line end
    end
    return 0
end

local IsDone

--- An accept step's item is in the bags: its giver offers the quest for it (`hd`, the library's
--- books), taken and turned in together.
local function Held(step) return step.id ~= nil and (FG.ItemCount(step.id) or 0) > 0 end

--- The quest's accept step was passed without accepting it (skipped by hand, left behind,
--- alternative done): its objectives and turn-in cannot be done.
local function AcceptSkipped(step, index)
    local at = acceptIndex[step.q]
    -- A book for the library in the bags: the quest is taken with its turn-in.
    if at and route.steps[at].hd and Held(route.steps[at]) then return false end
    return at ~= nil
        and at < index
        and not QuestLog.IsOnQuest(step.q)
        and not QuestLog.IsQuestFlaggedCompleted(step.q)
        and IsDone(route.steps[at], at)
end

--- Prerequisite `p` of the quest taken at step `index` will not be done: not done nor in the log,
--- and skipped by hand, its accept passed without taking it, or (built-in guides) carried in or
--- taken by an earlier guide of the chain and never done. A quest no guide plans is not judged:
--- the game data may list prerequisites the game does not ask for.
local function PrerequisiteLost(p, index)
    if QuestLog.IsQuestFlaggedCompleted(p) or QuestLog.IsOnQuest(p) then return false end
    if state.skippedQuests[p] then return true end
    local at = acceptIndex[p]
    if at then
        if at >= index or (route.steps[at].hd and Held(route.steps[at])) then return false end
        return (IsDone(route.steps[at], at))
    end
    return route.builtin == true and (turninIndex[p] ~= nil or plannedBefore[p] == true)
end

--- An accept step whose quest cannot be taken any more: a quest it needs will not be done.
local function PrerequisitesLost(step, index)
    for _, p in ipairs(step.pre or {}) do
        if PrerequisiteLost(p, index) then return true end
    end
    if step.pa then
        local need, open = math.min(step.pn or 1, #step.pa), 0
        for _, p in ipairs(step.pa) do
            if not PrerequisiteLost(p, index) then
                open = open + 1
                if open >= need then return false end
            end
        end
        return true
    end
    return false
end

--- XP of the quests complete in the log that the route turns in after grind step `index` and
--- before the level it aims at (the turn-in reaching it included): earned already, it counts.
--- Those turned in later do not, or the guide would be behind at its next steps.
local function PendingXP(step, index)
    local before = step.xp and step.lvl or step.lvl - 1
    local last = index
    while route.steps[last + 1] and (route.steps[last].lvl or 0) <= before do
        last = last + 1
    end
    local xp = 0
    for i = 1, QuestLog.GetNumQuestLogEntries() do
        local info = QuestLog.GetInfo(i)
        local q = info and not info.isHeader and info.questID
        local at = q and turninIndex[q]
        if
            at
            and at > index
            and at <= last
            and route.steps[at].rx
            and QuestLog.IsComplete(q)
            -- Quests without objectives (deliveries) are complete from the accept on.
            and not (objectiveQuests[q] and ObjectivesLoading(q))
        then
            xp = xp + route.steps[at].rx
        end
    end
    return xp
end

--- A hearthstone on a cooldown longer than this many seconds is not worth waiting for: the
--- step that sends the player home is passed. Shorter, the step stays (and waits for it).
Guide.HEARTH_WAIT = 300
local HEARTHSTONE, ASTRAL_RECALL = 6948, 556

--- Seconds left on a cooldown given as start and duration (0 when ready or unknown).
local function CooldownLeft(start, duration)
    if type(start) ~= "number" or type(duration) ~= "number" or start <= 0 or duration <= 0 then return 0 end
    return math.max(0, start + duration - GetTime())
end

--- Seconds since a cooldown started (nil when none is running or unknown).
local function CooldownElapsed(start, duration)
    if type(start) ~= "number" or type(duration) ~= "number" or start <= 0 or duration <= 0 then return nil end
    return GetTime() - start
end

-- A cooldown that started this recently (seconds) is the hearthstone the player just used.
local JUST_USED = 60

--- Whether Astral Recall is known and ready (its cooldown left at most Guide.HEARTH_WAIT).
local function RecallReady()
    if not (IsPlayerSpell and IsPlayerSpell(ASTRAL_RECALL)) then return false end
    local spell = C_Spell and C_Spell.GetSpellCooldown
    if spell then
        local ok, info = pcall(spell, ASTRAL_RECALL)
        if not ok or type(info) ~= "table" then return false end
        return CooldownLeft(info.startTime, info.duration) <= Guide.HEARTH_WAIT
    end
    if GetSpellCooldown then
        local ok, start, duration = pcall(GetSpellCooldown, ASTRAL_RECALL)
        return ok and CooldownLeft(start, duration) <= Guide.HEARTH_WAIT
    end
    return false
end

-- Bind steps written by an app or the guide builder carry their inn: `inn`, the English name
-- GetBindLocation gives, and `ia`, its AreaTable ids (the profile finds those of the bind's name in the
-- game's language). The table below is the fallback for guides written before that, by innkeeper NPC.
local INNS = {
    [5688] = { name = "Gallows' End Tavern", areas = {} },
}

-- How close (yards) a binding seen next to an innkeeper must be to count as that inn: the planner's
-- BIND_RADIUS.
local BIND_RADIUS = 60

--- Yards between the place the profile saw the character bind and a bind step, both turned into
--- world coordinates so that the map the game reported them on does not matter; nil when unknown.
local function BindDistance(at, step)
    if not (at and at.x and at.y and step.m and step.x and step.y) then return nil end
    if C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D and at.map then
        local c1, w1 = C_Map.GetWorldPosFromMapPos(at.map, CreateVector2D(at.x / 100, at.y / 100))
        local c2, w2 = C_Map.GetWorldPosFromMapPos(step.m, CreateVector2D(step.x / 100, step.y / 100))
        if c1 and c1 == c2 and w1 and w2 then
            local x1, y1 = w1:GetXY()
            local x2, y2 = w2:GetXY()
            return math.sqrt((x1 - x2) ^ 2 + (y1 - y2) ^ 2)
        end
    end
    -- No world positions: the same map in percent is all there is (about 1% of a zone).
    if at.map == step.m then return math.max(math.abs(at.x - step.x), math.abs(at.y - step.y)) * BIND_RADIUS end
    return nil
end

--- Whether the hearthstone is bound already to the inn of a bind step: GetBindLocation names it
--- (English name, or an area id of the step's `ia` among those the profile found for the bind's
--- name in the game's language), or the profile saw the character bind next to the innkeeper.
local function BoundHere(step)
    local name = GetBindLocation and GetBindLocation()
    if not name or name == "" then return false end
    local inn = INNS[step.id] or {}
    -- Neither source hides the other: a guide's own name is tried with the table's.
    if step.inn == name or inn.name == name then return true end
    local profile = PathwrightDB and PathwrightDB.profiles and PathwrightDB.profiles[FG:CharacterKey()]
    local bind = type(profile) == "table" and profile.bind
    if type(bind) ~= "table" or bind.name ~= name then return false end
    local wanted = {}
    for _, list in ipairs({ step.ia or {}, inn.areas or {} }) do
        for _, id in ipairs(list) do
            table.insert(wanted, id)
        end
    end
    for _, id in ipairs(bind.areas or {}) do
        for _, want in ipairs(wanted) do
            if id == want then return true end
        end
    end
    local d = BindDistance(bind.position, step)
    return d ~= nil and d <= BIND_RADIUS
end

--- Whether the way home is closed for long: the hearthstone is on a cooldown above
--- Guide.HEARTH_WAIT, and no Astral Recall is ready instead. A cooldown that has just started is
--- the hearthstone the player took, not a block. Without a hearthstone (or an API to ask),
--- nothing is known and the step stays as written.
local function HearthBlocked()
    local item = C_Container and C_Container.GetItemCooldown or GetItemCooldown
    if not item or not GetTime then return false end
    local ok, start, duration = pcall(item, HEARTHSTONE)
    if not ok or CooldownLeft(start, duration) <= Guide.HEARTH_WAIT then return false end
    local elapsed = CooldownElapsed(start, duration)
    if elapsed and elapsed < JUST_USED then return false end
    return not RecallReady()
end

--- Whether a step is done; the second value is true when it was passed rather than played
--- (marked by hand, left behind, alternative taken, accept skipped).
function IsDone(step, index)
    local q = step.q
    local group = FG.Group
    if state.marks[index or state.step] == "skip" or (q and state.skippedQuests[q]) then
        -- Marked as done by hand; in a group guide, once every player in the party did too.
        if group:SkipShared(step, index or state.step) then return true, true end
        return false
    end
    if group:Active() and step.mb then
        -- Players catching up: done once each one is where the guide plans it.
        if step.k == "grind" then return group:CaughtUp(step) end
        -- For other players (a quest we did already): done once those in the party are past it.
        if not group:ForMe(step) then return group:Passed(step, index or state.step), true end
    end
    -- Planned well below our level: left behind (a character resuming the route, a quest
    -- added to the game after we went through that zone), unless the quest is in the log. Not in
    -- an objective guide: its levels are only the character's when it was made.
    if
        step.lvl
        and not ObjectiveGuide()
        and UnitLevel("player") - step.lvl >= OUTDATED_LEVELS
        and not (q and QuestLog.IsOnQuest(q))
    then
        return true, true
    end
    -- An exclusive alternative (or the quest a breadcrumb leads to) is done or in progress:
    -- this quest cannot be taken any more.
    if step.alt and not QuestLog.IsOnQuest(q) then
        for _, other in ipairs(step.alt) do
            if QuestLog.IsQuestFlaggedCompleted(other) or QuestLog.IsOnQuest(other) then return true, true end
        end
    end
    if step.k == "accept" then
        if QuestLog.IsOnQuest(q) or QuestLog.IsQuestFlaggedCompleted(q) then return true end
        if step.hd and Held(step) then return true end
        -- A quest it needs was skipped (here or in an earlier guide): it cannot be taken.
        if PrerequisitesLost(step, index or state.step) then return true, true end
        -- Profession quest (optional): skipped without the skill it needs.
        if step.line and step.sk then
            local rank = FG.ProfessionSkill(step.line)
            return rank == nil or rank < step.sk
        end
        return false
    elseif step.k == "objective" then
        if QuestLog.IsQuestFlaggedCompleted(q) then return true end
        if AcceptSkipped(step, index or state.step) then return true, true end
        -- A quest taken before this guide (a built-in guide's "carry") that the character has not.
        if route.builtin and not acceptIndex[q] and not QuestLog.IsOnQuest(q) then return true, true end
        -- A child quest handed in on the way (Distracting Jarven for Bitter Rivals): done once
        -- turned in. Often repeatable, so the game does not keep it flagged.
        if step.cq then return state.handedIn[step.cq] or QuestLog.IsQuestFlaggedCompleted(step.cq) end
        -- An item to buy: done once in the bags, the quest taken or not yet.
        if step.by and step.id and (FG.ItemCount(step.id) or 0) >= (step.c or 1) then return true end
        if not QuestLog.IsOnQuest(q) or ObjectivesLoading(q) then return false end
        local o = FindObjective(step)
        if o then return o.finished end
        return QuestLog.IsComplete(q)
    elseif step.k == "turnin" then
        if QuestLog.IsQuestFlaggedCompleted(q) then return true end
        -- A quest taken before this guide (a built-in guide's "carry") that the character has not.
        if route.builtin and not acceptIndex[q] and not QuestLog.IsOnQuest(q) then return true, true end
        return AcceptSkipped(step, index or state.step), true
    elseif step.k == "abandon" then
        -- Done once the quest has left the log (or was never in it).
        return not QuestLog.IsOnQuest(q)
    elseif step.k == "grind" then
        -- To a level, or to an XP amount in it (grind placed before the end of the level), with
        -- the XP of the quests complete in the log the route turns in before that level.
        local level, xp = UnitLevel("player"), UnitXP("player") + PendingXP(step, index or state.step)
        local max = UnitXPMax("player")
        if max and max > 0 and xp >= max then
            level, xp = level + 1, xp - max
        end
        return level > step.lvl or (level == step.lvl and (not step.xp or xp >= step.xp))
    elseif step.k == "fly" then
        -- Done by its own take-off (see `Guide:Advance`): while in the air, the flights that follow
        -- in the group are not done.
        return state.marks[index or state.step] or false
    elseif step.k == "practice" then
        local rank = FG.ProfessionSkill(step.id)
        return rank ~= nil and rank >= step.sk
    elseif
        step.k == "profession"
        and step.sk
        and (select(2, FG.ProfessionSkill(ProfessionLine(step))) or 0) >= step.sk
    then
        return true -- rank already learned
    elseif step.k == "bind" then
        -- Done by talking to the innkeeper, or already bound to that inn.
        return state.marks[index or state.step] or BoundHere(step)
    elseif step.k == "flight_master" or step.k == "train" or step.k == "sell" or step.k == "profession" then
        return state.marks[index or state.step] or false
    elseif step.k == "dungeon" then
        -- Followed by the quests done inside (steps of their own): done on entering the dungeon.
        -- Guides made before: once back out of it.
        local mark = state.marks[index or state.step]
        local inside = route.steps[(index or state.step) + 1]
        if inside and inside.di then return mark == "inside" or mark == true end
        return mark == true
    elseif step.k == "hearth" then
        if state.marks[index or state.step] then return true end
        local d = Distance(step)
        if d ~= nil and d < 100 then return true end
        if HearthBlocked() then return true, true end
        return false
    elseif step.k == "deathskip" then
        -- Died on purpose: done once back at the spirit healer the step stands at.
        if state.marks[index or state.step] then return true end
        local d = Distance(step)
        return d ~= nil and d < 100
    elseif step.k == "teleport" then
        -- Placed at the class trainer of the city, a little off where the spell lands.
        if state.marks[index or state.step] then return true end
        local d = Distance(step)
        return d ~= nil and d < 300
    elseif step.k == "link" then
        local nextStep = route.steps[(index or state.step) + 1]
        return nextStep and nextStep.m and C_Map.GetBestMapForUnit("player") == nextStep.m or false
    elseif step.k == "goto" then
        -- A place to reach (built-in guides): done there, or marked.
        if state.marks[index or state.step] then return true end
        local d = Distance(step)
        return d ~= nil and d < (step.r or GOTO_RADIUS)
    elseif step.k == "note" then
        -- Something only the player sees (built-in guides): done once marked.
        if state.marks[index or state.step] then return true end
        -- A kill and loot (`hv`): done once the item is in the bags, so the player need not mark it.
        if step.hv and (FG.ItemCount(step.hv) or 0) > 0 then return true end
        -- The item is used for a quest (`hq`) later on (buried at Marla's Grave) and used up, so
        -- the note stays done once that quest's objective is fulfilled or it is turned in. Being
        -- on the quest alone does not count: it is taken before the kill.
        if step.hq then
            if QuestLog.IsQuestFlaggedCompleted(step.hq) then return true end
            if QuestLog.IsOnQuest(step.hq) and not ObjectivesLoading(step.hq) and QuestLog.IsComplete(step.hq) then
                return true
            end
        end
        -- A hearth with a cooldown check: passed when the hearthstone is far from ready.
        if step.t and step.t:find("Cooldown check item,6948", 1, true) and HearthBlocked() then return true, true end
        return false
    elseif not KINDS[step.k] then
        return true, true
    end
    return false
end

--- In a group guide, a step we did (not an objective: each one fills its own) waits for the
--- other players in the party it is for, until they did it too.
local function WaitsForGroup(step, index, passed)
    return not passed
        and step.k ~= "objective"
        and FG.Group:Active()
        and FG.Group:ForMe(step)
        and not FG.Group:Passed(step, index)
end

--- Names of the party members an objective we finished waits for: those running the addon who
--- have the quest and have not finished that objective (the "partyWait" setting, Party.lua). Not
--- a step passed by hand, nor a quest we handed in: taking and turning in wait for nobody.
local function PartyBehind(step, passed)
    if passed or step.k ~= "objective" or not step.q or not FG.Party or not FG.Party.Behind then return nil end
    if not FG:Get("partyWait") or not QuestLog.IsOnQuest(step.q) then return nil end
    local o, at = FindObjectiveIndex(step)
    local names = FG.Party:Behind(step.q, at, o and tonumber(o.numRequired))
    return names[1] and names or nil
end

local function WaitsForParty(step, passed) return PartyBehind(step, passed) ~= nil end

--- Whether an accept step's quest can be taken now: the quests it needs are done and the
--- character has its level (routes made before these were exported: always).
local function CanTake(step)
    if step.min and UnitLevel("player") < step.min then return false end
    for _, q in ipairs(step.pre or {}) do
        if not QuestLog.IsQuestFlaggedCompleted(q) then return false end
    end
    if step.pa then
        local need, done = math.min(step.pn or 1, #step.pa), 0
        for _, q in ipairs(step.pa) do
            if QuestLog.IsQuestFlaggedCompleted(q) then
                done = done + 1
                if done >= need then return true end
            end
        end
        return false
    end
    return true
end

--- Indexes of the next `max` accept steps not done whose quest can be taken now.
function Guide:Pickups(max)
    local out = {}
    if not route or not state then return out end
    for i = state.step, math.min(#route.steps, state.step + PICKUP_AHEAD) do
        if #out >= max then break end
        local s = route.steps[i]
        if s.k == "accept" and CanTake(s) and not IsDone(s, i) then table.insert(out, i) end
    end
    return out
end

-- Item class by item ID (12: quest items), false when the game does not know the item.
local itemClass = {}

--- Common items the guide's quests still need (not quest items: those only drop during their
--- quest): { { id, name, need, lvl, quests = { { q, name, count, lvl } } } }, the soonest first.
--- `lvl` is the level the guide plans to need it at. Kept until the quest is turned in.
function Guide:ItemsToKeep()
    local out, byItem = {}, {}
    if not route or not state then return out end
    for i, s in ipairs(route.steps) do
        -- A book for the library counts too: it is the quest's accept.
        if (s.k == "objective" and s.e == "item" or s.k == "accept" and s.hd) and s.id and s.q then
            local at = turninIndex[s.q]
            local turned = not at or IsDone(route.steps[at], at)
            local classID = itemClass[s.id]
            if classID == nil then
                classID = select(6, FG.ItemInfoInstant(s.id)) or false
                itemClass[s.id] = classID
            end
            if not turned and classID and classID ~= 12 then
                local item = byItem[s.id]
                if not item then
                    item = { id = s.id, name = s.n, need = 0, lvl = s.lvl, quests = {}, index = i }
                    byItem[s.id] = item
                    table.insert(out, item)
                end
                local seen = false
                for _, q in ipairs(item.quests) do
                    if q.q == s.q then seen = true end
                end
                if not seen then
                    local count = s.c or tonumber((s.t or ""):match("x(%d+)%s*$")) or 1
                    item.need = item.need + count
                    local accept = acceptIndex[s.q] and route.steps[acceptIndex[s.q]]
                    local name = QuestTitle(s) or (accept and accept.t) or s.t
                    table.insert(item.quests, { q = s.q, name = name, count = count, lvl = s.lvl })
                    -- A step without a level (a dungeon's quests): needed now.
                    if s.lvl then item.lvl = math.min(item.lvl or s.lvl, s.lvl) end
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.index < b.index end)
    return out
end

-- Groups: steps done around the same place, shown together and passed together. Cut once for the
-- route, so that a step is never on two pages: `groupStart[i]` is the first step of step i's
-- group, `groupEnd[first]` its last. Small on purpose: the same spot or the same NPC, a few
-- steps (the app's guides once marked wider groups, `gj`: not followed). Objectives (kills,
-- items, uses) whose mobs or places are next to the group's other objectives join it too: they
-- are done together, as what comes along. A checkpoint ("be level 2 and 53% to go on") does
-- not cut a group nor count in its size: it is shown after the group's other steps.
local groupStart, groupEnd = {}, {}

-- Map percents: within `GROUP_NEAR` of the group's first step; an objective within
-- `OBJECTIVE_NEAR` of one of the group's objectives (their spots too) and within
-- `OBJECTIVE_SPREAD` of the first; the first objective after visits within `SPOT_NEAR`.
local GROUP_NEAR, OBJECTIVE_NEAR, OBJECTIVE_SPREAD, SPOT_NEAR = 2.5, 4, 8, 2

--- A level or XP checkpoint: done when the character has the XP, whatever it did meanwhile.
local function Checkpoint(step) return step.k == "grind" and step.kp == true end

local function Within(a, b, d)
    return a.m == b.m and a.x and b.x and math.abs(a.x - b.x) < d and math.abs(a.y - b.y) < d or false
end

--- Whether objective `s` is done along with objective `o`: one of their places next to the other's.
local function Together(s, o)
    if Within(s, o, OBJECTIVE_NEAR) then return true end
    for _, p in ipairs(s.spots or {}) do
        if Within(p, o, OBJECTIVE_NEAR) then return true end
        for _, q in ipairs(o.spots or {}) do
            if Within(p, q, OBJECTIVE_NEAR) then return true end
        end
    end
    for _, q in ipairs(o.spots or {}) do
        if Within(s, q, OBJECTIVE_NEAR) then return true end
    end
    return false
end

--- Whether step `s` can be in a group with other steps: not a trip, nor a grind held until a level.
local function Opens(s) return s.k ~= "fly" and s.k ~= "link" and s.k ~= "grind" end

--- Whether step `s` joins the group of `first` holding the objectives `objectives`.
local function Joins(s, first, objectives)
    if not s.m or not s.x or s.m ~= first.m or not Opens(s) then return false end
    -- The same NPC (or mob, object) elsewhere.
    if s.id ~= nil and s.id == first.id then return true end
    -- The first objective after visits (a town): on the spot only, else it opens the page of the
    -- objectives done around it.
    if s.k == "objective" and #objectives == 0 then return Within(s, first, SPOT_NEAR) end
    if Within(s, first, GROUP_NEAR) then return true end
    if s.k ~= "objective" or not Within(s, first, OBJECTIVE_SPREAD) then return false end
    for _, o in ipairs(objectives) do
        if Together(s, o) then return true end
    end
    return false
end

local function BuildGroups()
    wipe(groupStart)
    wipe(groupEnd)
    local steps = route and route.steps or {}
    local i = 1
    while i <= #steps do
        local start, last = steps[i], i
        -- A dungeon: entered, then the steps done inside it (`di`), one group whatever their
        -- places and number, shown until every one is done.
        if start.k == "dungeon" and steps[i + 1] and steps[i + 1].di then
            last = i + 1
            while steps[last + 1] and steps[last + 1].di do
                last = last + 1
            end
            start = nil
        end
        -- A group opened by a checkpoint (placed where the step before it was): the step after it,
        -- when close, says where the group is.
        local first = start and not Checkpoint(start) and start or nil
        local size, objectives = first and 1 or 0, {}
        if first and first.k == "objective" then table.insert(objectives, first) end
        if start and start.m then
            for j = i + 1, #steps do
                local s = steps[j]
                if Checkpoint(s) then
                    if s.m ~= start.m then break end
                elseif not first then
                    if not Joins(s, start, objectives) then break end
                    first, size = s, 1
                else
                    if size >= GROUP_MAX or not Joins(s, first, objectives) then break end
                    size = size + 1
                end
                if s.k == "objective" and s.x then table.insert(objectives, s) end
                last = j
            end
        end
        for k = i, last do
            groupStart[k] = i
        end
        groupEnd[i] = last
        i = last + 1
    end
end

-- Whether each step of the groups looked at was done at the last check (steps done while playing
-- are recorded once, when they become done).
local wasDone = {}
local wasOnTaxi = false

--- The first and last steps of step `index`'s group.
local function GroupOf(index)
    local first = groupStart[index] or index
    return first, groupEnd[first] or first
end

--- When the current group is a dungeon (entered, then its steps inside): its entrance step and
--- the indexes of its steps not done yet.
local function DungeonLeft()
    local first, last = GroupOf(state.step)
    local entrance, inside = route.steps[first], route.steps[first + 1]
    if not entrance or entrance.k ~= "dungeon" or not (inside and inside.di) then return nil end
    local left = {}
    for i = first, math.min(last, #route.steps) do
        local step = route.steps[i]
        if not step.bg and not IsDone(step, i) then table.insert(left, i) end
    end
    if #left == 0 then return nil end
    return entrance, left
end

--- The steps of the current step's group, shown together.
local function CurrentGroup()
    local first, last = GroupOf(state.step)
    local group = {}
    for i = first, math.min(last, #route.steps) do
        table.insert(group, i)
    end
    return group
end

--- Distance in yards from the player to a step, when both are on the same continent.
function Distance(step)
    if not step.m or not C_Map.GetWorldPosFromMapPos then return nil end
    local playerMap = C_Map.GetBestMapForUnit("player")
    local pos = playerMap and C_Map.GetPlayerMapPosition(playerMap, "player")
    if not pos then return nil end
    local c1, w1 = C_Map.GetWorldPosFromMapPos(playerMap, pos)
    local c2, w2 = C_Map.GetWorldPosFromMapPos(step.m, CreateVector2D(step.x / 100, step.y / 100))
    if not c1 or c1 ~= c2 or not w1 or not w2 then return nil end
    local x1, y1 = w1:GetXY()
    local x2, y2 = w2:GetXY()
    return math.sqrt((x1 - x2) ^ 2 + (y1 - y2) ^ 2)
end

-- Other places ---------------------------------------------------------------
-- A step whose mobs live in several places (`spots`, the closest first): the compass points at
-- its own place, then at the closest one not visited yet once the character has stood at the
-- shown one a while without fighting (nothing there), or on "Next spot" (a key binding). For the session only.
-- An NPC who patrols (`pt`): its spots are along its path, and the closest place to the
-- character is pointed at first.

-- At a place within this many yards; moved on after this many seconds there out of combat.
local SPOT_NEAR, SPOT_WAIT = 40, 20
local spot = { index = nil, step = nil, at = 1, visited = {}, since = nil }
local placesOf = setmetatable({}, { __mode = "k" })

--- A step's places: itself, then its spots (same text and zone).
local function Places(step)
    local places = placesOf[step]
    if not places then
        places = { step }
        for _, p in ipairs(step.spots or {}) do
            table.insert(places, { m = p.m, x = p.x, y = p.y, n = step.n, zone = step.zone, t = step.t, alt = true })
        end
        placesOf[step] = places
    end
    return places
end

--- Point at the closest place not visited yet (all visited: around again).
local function NextSpot(places)
    spot.visited[spot.at] = true
    local best, bestDistance
    for pass = 1, 2 do
        for i, p in ipairs(places) do
            if not spot.visited[i] then
                local d = Distance(p) or math.huge
                if not best or d < bestDistance then
                    best, bestDistance = i, d
                end
            end
        end
        if best then break end
        spot.visited = { [spot.at] = true }
    end
    spot.at, spot.since = best or 1, nil
end

--- Where to point for step `index`: the place shown among its own and its spots, moving on
--- when the character has waited at it out of combat.
local function SpotTarget(step, index)
    if not step.spots then return step end
    local places = Places(step)
    -- Another step, or the same index of another guide.
    if spot.index ~= index or spot.step ~= step then
        spot.index, spot.step, spot.at, spot.visited, spot.since = index, step, 1, {}, nil
        if step.pt then
            local best
            for i, p in ipairs(places) do
                local d = Distance(p)
                if d and (not best or d < best) then
                    best, spot.at = d, i
                end
            end
        end
    end
    local d = Distance(places[spot.at])
    if d and d < SPOT_NEAR and not UnitAffectingCombat("player") then
        spot.since = spot.since or GetTime()
        if GetTime() - spot.since >= SPOT_WAIT then NextSpot(places) end
    else
        spot.since = nil
    end
    return places[spot.at]
end

--- The places of the step pointed at (its own, then its spots) and the one shown; nil when it
--- has no other place.
function Guide:SpotPlaces()
    local step = route and spot.index and route.steps[spot.index]
    if not step or not step.spots then return nil end
    return Places(step), spot.at
end

local function SetWaypoint(step)
    -- Shortest Path Forever guides there with the game's waypoint.
    if FG.Pathing and FG.Pathing:Guiding() then
        waypointStep = nil
        return
    end
    if not FG:Get("uiShown") or not step or not step.m or not FG:Get("waypoints") or step == waypointStep then
        return
    end
    waypointStep = step
    -- Map pins need a client that has them (not Classic Era).
    if C_Map.CanSetUserWaypointOnMap and C_Map.CanSetUserWaypointOnMap(step.m) then
        C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(step.m, step.x / 100, step.y / 100))
        if C_SuperTrack then C_SuperTrack.SetSuperTrackedUserWaypoint(true) end
    end
end

-- What to show -----------------------------------------------------------------
-- Guide:Refresh builds a description of what to show (the "view") and hands it to the guide's
-- look of the moment: FG.Card (full) or FG.Mini (minimal). Tasks: { kind, index, step, icon,
-- name, sub, chips = { { text, color } }, have, need, done, target }; a "farm" task is the mobs to
-- kill on the way to the step after it.

local function Chip(v, text, color) table.insert(v.chips, { text = text, color = color }) end

--- A number with its thousands apart, as the game writes them in the client's language.
local function Thousands(n)
    n = math.floor(n + 0.5)
    if BreakUpLargeNumbers then return BreakUpLargeNumbers(n) end
    local sign, digits = tostring(n):match("^(-?)(%d+)$")
    if not digits then return tostring(n) end
    local head = #digits % 3
    local parts = {}
    if head > 0 then table.insert(parts, digits:sub(1, head)) end
    for i = head + 1, #digits, 3 do
        table.insert(parts, digits:sub(i, i + 2))
    end
    return sign .. table.concat(parts, ",")
end

--- What the guide shows for a step: its name, the line under it (quest, NPC, why), warnings and
--- the progress when known (`withProgress`).
local function TaskView(step, index, withProgress)
    local kind = KINDS[step.k] or OTHER
    local title = QuestTitle(step)
    local v = { index = index, step = step, kind = step.k, icon = StepIcon(step, kind), color = kind.color, chips = {} }
    if step.k == "accept" or step.k == "turnin" then
        v.name = title or step.t
        if title then v.sub = kind.label .. (step.n and (" • " .. step.n) or "") end
        -- A turn-in whose quest is not complete yet (objectives passed by hand): how far it is.
        if step.k == "turnin" and withProgress and QuestLog.IsOnQuest(step.q) and not QuestLog.IsComplete(step.q) then
            local have, need = 0, 0
            for _, o in ipairs(QuestLog.GetQuestObjectives(step.q) or {}) do
                if (o.numRequired or 0) > 0 then
                    have = have + math.min(o.numFulfilled or 0, o.numRequired)
                    need = need + o.numRequired
                end
            end
            if need > 0 then
                v.have, v.need = have, need
            end
        end
        -- Reward the guide picked (it counts on wearing it).
        local reward = step.rw and C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(step.rw)
        if reward then Chip(v, reward, "green") end
    elseif step.k == "train" and step.sp then
        -- Spells worth learning, in the game's language.
        local names = {}
        for _, id in ipairs(step.sp) do
            local name = FG.SpellName(id)
            if not name then break end
            local rank = GetSpellSubtext and GetSpellSubtext(id)
            names[#names + 1] = (rank and rank ~= "") and (name .. " (" .. rank .. ")") or name
        end
        v.name = #names == #step.sp and table.concat(names, ", ") or step.t
        v.sub = kind.label .. (step.n and (" • " .. step.n) or "")
    elseif step.k == "objective" then
        v.name = step.n or step.t
        if withProgress then
            local o = QuestLog.IsOnQuest(step.q) and FindObjective(step)
            if o and o.numRequired and o.numRequired > 0 then
                v.have, v.need = o.numFulfilled, o.numRequired
            end
        end
        v.sub = title
        if step.bg then Chip(v, L.alongTheWay, "lightBlue") end
        -- Danger: elite mobs, or mobs well above the character.
        if step.el then Chip(v, L.elite, "red") end
        if step.ml and step.ml >= UnitLevel("player") + 3 then Chip(v, L.level .. " " .. step.ml, "orange") end
    elseif step.k == "abandon" then
        -- The quest's name as the game says it, then the label and why: "Abandon (not in this
        -- guide)" of the guide's text without its verb.
        local why = step.t and step.t:match("(%b())%s*$")
        v.name = title or step.t
        v.sub = kind.label .. (title and why and (" " .. why) or "")
    elseif step.k == "practice" then
        v.name = step.t
        local rank = withProgress and FG.ProfessionSkill(step.id)
        if rank then
            v.have, v.need = rank, step.sk
        end
    else
        v.name = step.t
    end
    local done, passed = IsDone(step, index)
    FG.Group:Chips(step, index, function(text, color) Chip(v, text, color) end, done)
    -- An objective we finished that waits for the party (the "partyWait" setting).
    local behind = done and PartyBehind(step, passed)
    if behind then Chip(v, string.format(L.partyWaits, table.concat(behind, ", ")), "orange") end
    -- Drawn after the name (the name alone goes to the compass and the arrow).
    v.mark = NoteMark(step)
    -- Your time on its quest, the drop rate of its item, the score (Stats.lua): small, under the count.
    v.stats = FG.Stats and FG.Stats:StepLine(step)
    -- The party's progress on the same objective (Party.lua): "Name (3/8)" for each member.
    if step.k == "objective" and step.q and FG.Party and QuestLog.IsOnQuest(step.q) then
        local o, at = FindObjectiveIndex(step)
        if at then v.party = FG.Party:Members(step.q, at, o and o.numRequired) end
        if v.party and not v.party[1] then v.party = nil end
    end
    -- An objective guide done below the level its quests ask: said on the current step until reached.
    local recommended = route and route.recommendedLevel
    if recommended and state and index == state.step and UnitLevel("player") < recommended then
        Chip(v, string.format(L.recommended, recommended, UnitLevel("player")), "orange")
    end
    -- A quest the character cannot take yet (the guide planned the level a little early): the
    -- current step stays, and says to do the next steps and come back; the quest is also kept out
    -- of the pickups ahead (CanTake) until the level is reached.
    if step.k == "accept" and state and index == state.step and step.min and UnitLevel("player") < step.min then
        Chip(v, string.format(L.needsLevel, step.min, UnitLevel("player")), "orange")
    end
    return v
end

--- A line of the next steps: { index, kind, color, text, who }.
local function NextView(step, index)
    local kind = KINDS[step.k] or OTHER
    local title = QuestTitle(step)
    local v = { index = index, step = step, kind = step.k, color = kind.color, icon = StepIcon(step, kind) }
    if title and (step.k == "accept" or step.k == "turnin") then
        v.text, v.who = kind.label .. " " .. title, step.n
    elseif step.k == "train" then
        v.text, v.who = kind.label, step.n
    else
        v.text = step.t
    end
    v.text = (v.text or "") .. NoteMark(step, 12)
    return v
end

--- Name of a map (zone), nil when unknown.
local function ZoneName(map)
    local info = map and C_Map.GetMapInfo and C_Map.GetMapInfo(map)
    return info and info.name or nil
end

--- The next checkpoint already reached in level, and the steps before it that can be skipped
--- (not kept, not done yet, not the turn-in of a finished quest).
local function Ahead()
    local level = UnitLevel("player")
    for _, c in ipairs(route.checkpoints or {}) do
        if c.step > state.step then
            if level < c.lvl then return nil end
            local skip = {}
            for index = state.step, c.step - 1 do
                local step = route.steps[index]
                local finished = step.k == "turnin" and QuestLog.IsOnQuest(step.q) and QuestLog.IsComplete(step.q)
                if not step.kp and not step.bg and not finished and not IsDone(step, index) then
                    table.insert(skip, index)
                end
            end
            if #skip == 0 then return nil end
            return c, skip
        end
    end
    return nil
end

--- Skip to the next checkpoint (see Ahead).
function Guide:SkipAhead()
    local c, skip = Ahead()
    if not c then return end
    for _, index in ipairs(skip) do
        state.marks[index] = "skip"
    end
    FG:Print(L.ahead, c.lvl, #skip)
    self:Resync()
end

--- Leave the dungeon under way aside: its quests not finished (all their steps, those outside
--- it too), and its other steps not done, are marked as done.
function Guide:SkipDungeon()
    if not route then return end
    local entrance, left = DungeonLeft()
    if not entrance then return end
    local many = {}
    for _, index in ipairs(left) do
        local q = route.steps[index].q
        if q then
            if not state.skippedQuests[q] then
                state.skippedQuests[q] = true
                table.insert(many, { q = q })
            end
        else
            state.marks[index] = "skip"
            table.insert(many, { index = index })
        end
    end
    lastMark = { route = route, many = many }
    FG:Print(L.dungeonSkipped, entrance.n or entrance.t, #left)
    FG.Group:MarksChanged()
    self:Resync()
end

--- The guide's look of the moment (FG.Card or FG.Mini), the other hidden; nil before login.
function Guide:UI()
    if not FG.Card or not FG.Card:Frame() then return nil end
    local minimal = FG:Get("guideMode") == "minimal" and FG.Mini
    if minimal then
        FG.Card:Hide()
        return FG.Mini
    end
    if FG.Mini then FG.Mini:Hide() end
    return FG.Card
end

--- Switch between the full guide and the minimal one (kept for the next sessions).
function Guide:ToggleMode() FG:Save("guideMode", FG:Get("guideMode") == "minimal" and "full" or "minimal") end

--- Tooltip of a step's line: its full text, then what clicks do.
function Guide:StepTooltip(owner, index)
    local step = index and route and route.steps[index]
    if not step then return end
    GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    GameTooltip:AddLine(step.t, 1, 1, 1, true)
    -- Its quest notes, the one that matters most first (as the app sorts them).
    for _, n in ipairs(step.nt or {}) do
        local level = math.max(1, math.min(3, tonumber(n.l) or 1))
        local c = NOTE_COLOR[level]
        GameTooltip:AddLine(NoteMark({ nt = { n } }, 12) .. " " .. (n.t or ""), c[1], c[2], c[3], true)
    end
    if step.fx or step.fk then GameTooltip:AddLine(L.farmTip, 0.75, 0.5, 1, true) end
    for _, line in ipairs(FG.Stats and FG.Stats:TooltipLines(step) or {}) do
        GameTooltip:AddLine(line, 0.65, 0.8, 1, true)
    end
    GameTooltip:AddLine(L.pointHint, 0.6, 0.6, 0.6, true)
    GameTooltip:AddLine(L.skipHint, 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
end

-- Steps done by talking to their NPC: it is marked above its head when its nameplate shows.
local TALKS = { accept = true, turnin = true, train = true, bind = true, flight_master = true, fly = true }

-- The compass shows the quests to pick up closer than this (yards).
local PICKUP_NEAR = 100

-- A route can introduce a quest objective along the way and revisit it at a different spot.
local function ObjectiveKey(step)
    if step.k ~= "objective" or not step.q then return nil end
    local index = step.o or select(2, FindObjectiveIndex(step))
    if index then return step.q .. ":o:" .. index end
    if step.e and step.id then return step.q .. ":" .. step.e .. ":" .. step.id end
    if step.n then return step.q .. ":name:" .. step.n end
end

function Guide:Refresh()
    local ui = self:UI()
    if not ui then return end
    -- A guide finished that names the one after it: that one opens in a tab, once (closing it
    -- and coming back to the finished guide does not open it again).
    if route and not route.steps[state.step] and route.next and FG.Routes and FG.Routes[route.next] then
        state.nextOpened = state.nextOpened or {}
        if not state.nextOpened[state.route] then
            state.nextOpened[state.route] = true
            FG:Print(L.nextGuide, route.next)
            return self:Choose(route.next)
        end
    end
    local shown = FG:Get("guideShown")
    if not shown or not route or not route.steps[state.step] then
        if FG.Compass then FG.Compass:SetPoints(nil) end
        if FG.Pathing then FG.Pathing:SetTarget(nil) end
        if FG.Arrow then FG.Arrow:SetTarget(nil) end
        ui:Render({
            hidden = not shown,
            message = route and L.done or (next(FG.Routes or {}) and L.noRoute or L.noGuides),
        })
        if FG.Tabs then FG.Tabs:Render(ui) end
        if FG.Toolstrip then FG.Toolstrip:SetSteps({}) end
        return
    end

    local group = CurrentGroup()
    -- Arrived on a page: what is done already there (not recorded as played when seen done).
    for _, index in ipairs(group) do
        if wasDone[index] == nil then
            local step = route.steps[index]
            wasDone[index] = (step.bg or IsDone(step, index)) and true or false
        end
    end
    local view = { tasks = {}, next = {}, pickups = {} }
    local target, targetIndex
    local todo = {}
    local listed = {}
    local preferred = {}
    local function Add(index, done)
        local step = route.steps[index]
        if step.bg then
            local key = ObjectiveKey(step)
            if key then
                if preferred[key] and preferred[key] ~= index then
                    if pointed == index then pointed = preferred[key] end
                    return
                end
                preferred[key] = index
            end
        end
        -- The mobs to kill on the way to a step: a line of their own before it, counted while it
        -- is the current step, greyed with it once it is done (the XP bar's box still holds
        -- their XP).
        if step.fx or step.fk then
            local farm = index == state.step and state.farm and state.farm.step == index and state.farm or nil
            -- The XP of the kills (guides made before: their number).
            local need = step.fx or step.fk
            local have = farm and (step.fx and farm.xp or farm.kills) or nil
            have = have and math.min(have, need)
            local count
            if not step.fx then
                count = have and string.format("%d/%d", have, need) or ("~" .. need)
            elseif have then
                count = string.format(L.farmXP, Thousands(have), Thousands(need))
            else
                count = string.format(L.farmXPPlanned, Thousands(need))
            end
            table.insert(view.tasks, {
                kind = "farm",
                index = index,
                step = step,
                icon = KINDS.grind.icon,
                have = have,
                need = need,
                count = count,
                done = done or (have ~= nil and have >= need),
                chips = {},
            })
        end
        listed[index] = true
        -- An objective we finished that waits for the party stays a task to do: its row keeps the
        -- party's progress, and the toolstrip its target buttons, to help the member finish.
        if done and not step.bg and WaitsForParty(step, select(2, IsDone(step, index))) then done = false end
        if not done then table.insert(todo, step) end
        local v = TaskView(step, index, true)
        v.done = done
        table.insert(view.tasks, v)
        if not done and not target then
            target, targetIndex = step, index
        end
    end
    -- Objectives in progress done along the way (left behind, not finished): shown until done,
    -- before the page's steps when the page turns their quest in.
    local turnedIn = {}
    for _, index in ipairs(group) do
        local step = route.steps[index]
        -- Reserve current objectives before either pass adds unfinished background steps.
        local key = ObjectiveKey(step)
        if key and (not preferred[key] or not step.bg) then preferred[key] = index end
        if step.k == "turnin" and step.q then turnedIn[step.q] = true end
    end
    local function AlongTheWay(first)
        for index = 1, group[1] - 1 do
            local step = route.steps[index]
            -- An item offered at a vendor passed by (`tr`) is not followed once behind.
            if
                step.bg
                and not step.tr
                and not listed[index]
                and (turnedIn[step.q] or false) == first
                and QuestLog.IsOnQuest(step.q)
                and not IsDone(step, index)
            then
                Add(index, false)
            end
        end
    end
    AlongTheWay(true)
    -- The group's checkpoints after its other steps: what is done there gets the XP.
    for pass = 1, 2 do
        for _, index in ipairs(group) do
            local step = route.steps[index]
            if Checkpoint(step) == (pass == 2) then Add(index, IsDone(step, index)) end
        end
    end
    AlongTheWay(false)
    if FG.MapPins then FG.MapPins:Refresh() end
    if not target then
        target, targetIndex = route.steps[state.step], state.step
    end
    if pointed and (not route.steps[pointed] or IsDone(route.steps[pointed], pointed)) then pointed = nil end
    if pointed then
        target, targetIndex = route.steps[pointed], pointed
    end
    local hasSpots = target.spots ~= nil
    local place = SpotTarget(target, targetIndex)
    if detour and (Distance(detour) or math.huge) < DETOUR_ARRIVED then detour = nil end
    if detour then place = detour end
    for _, v in ipairs(view.tasks) do
        v.target = not detour and v.kind ~= "farm" and v.index == targetIndex and not v.done
    end

    view.step, view.total = state.step, #route.steps
    view.level, view.planned = UnitLevel("player"), route.steps[state.step].lvl
    view.timing = FG.Timing and FG.Timing:Short():gsub("^%s+", "") or ""
    view.zone = ZoneName(place.m) or ZoneName(C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player"))
    view.target, view.targetIndex = place, targetIndex
    view.distance = Distance(place)
    view.coords = place.m and string.format("%.1f, %.1f", place.x, place.y) or nil
    view.spot = hasSpots and string.format(L.spot, spot.at, #Places(route.steps[spot.index])) or nil
    local c, skip = Ahead()
    view.ahead = c and { lvl = c.lvl, steps = #skip } or nil
    local entrance, left = DungeonLeft()
    view.dungeon = entrance and { name = entrance.n or entrance.t, steps = #left } or nil
    view.talent = FG.Talents and FG.Talents:Pending()
    view.nextTab = FG:Get("nextTab") == "pickup" and "pickup" or "next"

    -- The next steps after the current ones (those done already greyed, those done along the way
    -- left out), with the place where the guide plans the next level.
    local index, last = group[#group] + 1, group[#group] + PICKUP_AHEAD
    -- A step without a level (a dungeon's quests): later levels are marked against our own.
    local level, marked, nextTurnIn = view.planned or view.level, false, nil
    while #view.next < 12 and route.steps[index] and index <= last do
        local step = route.steps[index]
        if not step.bg and not listed[index] then
            if not marked and level and step.lvl and step.lvl > level then
                table.insert(view.next, { marker = step.lvl })
                marked = true
            end
            local v = NextView(step, index)
            v.done = IsDone(step, index) and true or false
            table.insert(view.next, v)
            if step.k == "turnin" and not nextTurnIn and not v.done then nextTurnIn = index end
        end
        index = index + 1
    end
    -- Quests to pick up: in the route's order, with their distance, to take the close ones in the
    -- order that suits.
    for _, i in ipairs(self:Pickups(10)) do
        local step = route.steps[i]
        local v = NextView(step, i)
        v.text = QuestTitle(step) or step.t
        v.who = QuestTitle(step) and step.n or nil
        v.distance = Distance(step)
        table.insert(view.pickups, v)
    end

    do
        local info = detour and { title = detour.name, kind = detour.service, npc = detour.npc }
            or {
                title = TaskView(target, targetIndex, false).name,
                kind = target.k,
                q = target.q,
                npc = place == target and target.e == "npc" and TALKS[target.k] and target.id or nil,
            }
        if FG.Pathing then FG.Pathing:SetTarget(place, not detour and target or nil, info) end
        if FG.PathLines then FG.PathLines:Refresh() end
        if FG.Arrow then FG.Arrow:SetTarget(place, info.title) end
    end
    SetWaypoint(place)
    if FG.Compass and not FG:Get("compassShown") then
        FG.Compass:SetPoints(nil)
    elseif FG.Compass then
        -- The target, the other tasks, the close quests to pick up and the next turn-in.
        local points = {}
        local function Point(step, i, main, task)
            if not step or not step.m or not step.x then return end
            local v = TaskView(route.steps[i], i, false)
            table.insert(points, {
                m = step.m,
                x = step.x,
                y = step.y,
                index = i,
                main = main,
                task = task,
                kind = v.kind,
                icon = v.icon,
                name = v.name,
                sub = v.sub,
            })
        end
        if detour then
            table.insert(points, {
                m = detour.m,
                x = detour.x,
                y = detour.y,
                main = true,
                place = true,
                icon = detour.icon,
                name = detour.name,
                sub = detour.sub,
            })
        else
            Point(place, targetIndex, true)
        end
        for _, v in ipairs(view.tasks) do
            if v.kind ~= "farm" and not v.done and (detour or v.index ~= targetIndex) then
                Point(v.step, v.index, false, true)
            end
        end
        for _, v in ipairs(view.pickups) do
            if v.distance and v.distance <= PICKUP_NEAR and not listed[v.index] then Point(v.step, v.index) end
        end
        if nextTurnIn then Point(route.steps[nextTurnIn], nextTurnIn) end
        FG.Compass:SetPoints(points)
    end
    self.view = view
    -- The toolstrip's actions before the card is drawn: it makes room for those it shows itself.
    if FG.Toolstrip then view.actions = FG.Toolstrip.Actions(todo) end
    ui:Render(view)
    if FG.Tabs then FG.Tabs:Render(ui) end
    if FG.Toolstrip then FG.Toolstrip:SetSteps(todo, view.actions) end
end

-- Navigation -------------------------------------------------------------------

--- Skip forward over finished steps. `fromEvent` resumes after manual navigation.
--- Skip the following steps already done (they are done together, e.g. several quests
--- accepted at once).
local function SkipDone()
    -- Background objectives (done along the way) do not stop the guide: the tracker shows them.
    while route.steps[state.step] do
        local step = route.steps[state.step]
        local done, passed = step.bg, step.bg
        if not done then
            done, passed = IsDone(step, state.step)
        end
        if not done or WaitsForGroup(step, state.step, passed) or WaitsForParty(step, passed) then break end
        state.step = state.step + 1
    end
    arrivedDone = false
end

--- Move on once every step of the current group is done (not when we navigated to a group done
--- already); until then the current step is the group's first one not done.
function Guide:Advance()
    if route and route.steps[state.step] then
        -- A take-off is the flight of the first fly step of the group not taken yet.
        local onTaxi = UnitOnTaxi("player") and true or false
        if onTaxi and not wasOnTaxi then
            for _, index in ipairs(CurrentGroup()) do
                if route.steps[index].k == "fly" and not state.marks[index] then
                    state.marks[index] = true
                    break
                end
            end
        end
        wasOnTaxi = onTaxi
        local first, last = GroupOf(state.step)
        local pending
        for i = first, math.min(last, #route.steps) do
            local step = route.steps[i]
            local done, passed = step.bg, step.bg
            if not done then
                done, passed = IsDone(step, i)
            end
            -- Done while playing: recorded with its index (not the background ones, nor passed).
            if done and not passed and wasDone[i] == false and FG.Collector then
                FG:Try("step", FG.Collector.RecordStep, FG.Collector, i, step)
            end
            wasDone[i] = done and true or false
            -- The group's checkpoints come last (see Refresh).
            if
                (not done or WaitsForGroup(step, i, passed) or WaitsForParty(step, passed))
                and (not pending or Checkpoint(route.steps[pending]) and not Checkpoint(step))
            then
                pending = i
            end
        end
        if pending then
            arrivedDone = false
            state.step = pending
        elseif not arrivedDone then
            state.step = last + 1
            SkipDone()
        end
    end
    self:Refresh()
end

--- The first step of the next group (the guide's › button, a key binding).
function Guide:NextGroup()
    if not route then return end
    local _, last = GroupOf(state.step)
    self:Go(last + 1)
end

--- The first step of the group before (the guide's ‹ button, a key binding).
function Guide:PrevGroup()
    if not route then return end
    local first = GroupOf(state.step)
    self:Go(GroupOf(math.max(1, first - 1)))
end

-- Steps the game cannot tell were done (visits, notes, places, flights): passed once a quest step
-- after them is done.
local VISITS = {
    flight_master = true,
    train = true,
    sell = true,
    bind = true,
    profession = true,
    note = true,
    ["goto"] = true,
    fly = true,
    hearth = true,
    deathskip = true,
    teleport = true,
}

local QUEST_STEPS = { accept = true, turnin = true, objective = true }

--- The visits (merchant, trainer, flight master, inn) followed by a quest step the character
--- did are done: their marks are lost with a new version of the guide or a character joining it
--- halfway, and the game cannot say whether a merchant was seen. Only up to the first quest step
--- not done: a quest handed in far ahead of the guide does not pass the visits on the way to it.
local function PassVisits()
    local pending = {}
    for i, step in ipairs(route.steps) do
        if VISITS[step.k] then
            if not state.marks[i] then table.insert(pending, i) end
        elseif QUEST_STEPS[step.k] and not step.bg then
            local done, passed = IsDone(step, i)
            if not done then break end
            -- Marked by hand: says nothing of where the character went.
            if not passed then
                for _, index in ipairs(pending) do
                    state.marks[index] = true
                end
                pending = {}
            end
        end
    end
end

--- Whether a step is done (for tests and other windows).
function Guide:IsDone(step, index) return IsDone(step, index) end

--- Go to the first step not done yet (route change, or the resync button); `resume`: from the
--- step the character was on (login), since steps the game cannot say are done (a kill count, a
--- grind, a use) would otherwise stop the guide far behind.
function Guide:Resync(resume)
    if route then
        PassVisits()
        if not (resume and route.steps[state.step]) then state.step = 1 end
        SkipDone()
    end
    waypointStep, pointed, detour = nil, nil, nil
    self:Refresh()
end

--- The steps and quests marked done by hand (by mistake, or no longer wanted).
local function HandMarks()
    local n = 0
    for _, mark in pairs(state.marks) do
        if mark == "skip" then n = n + 1 end
    end
    for _ in pairs(state.skippedQuests) do
        n = n + 1
    end
    return n
end

--- Start the guide over from what the game knows: the steps and quests marked done by hand are
--- no longer, then the first step not done. The visits seen (flight paths, trainers, dungeons)
--- stay done.
function Guide:Reset()
    if not route then return end
    for index, mark in pairs(state.marks) do
        if mark == "skip" then state.marks[index] = nil end
    end
    wipe(state.skippedQuests)
    state.farm = nil
    FG:Print(L.resetDone)
    self:Resync()
end

StaticPopupDialogs["PATHWRIGHT_RESET"] = {
    text = L.resetConfirm,
    button1 = YES,
    button2 = NO,
    OnAccept = function() Guide:Reset() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

--- The guide's start-over button: asks first when steps or quests were marked by hand.
function Guide:AskReset()
    local n = route and HandMarks() or 0
    if n > 0 then
        StaticPopup_Show("PATHWRIGHT_RESET", n)
    else
        self:Resync()
    end
end

--- Whether killing creature `npc` still counts for a quest the guide does: an objective step
--- is done on it (killed, or dropping its item), its quest is in the log and that objective is
--- not finished. Such a kill is not a mob on the way; once the objective is done, it is.
local function QuestMob(npc)
    for _, index in ipairs(npc and questMobs[npc] or {}) do
        local s = route.steps[index]
        if QuestLog.IsOnQuest(s.q) and not IsDone(s, index) then return true end
    end
    return false
end

--- XP earned from a kill (`xp`; `quest`: the mob was one of an objective in progress): counted
--- for the current step when it has mobs to kill on the way to it, unless it was a quest mob.
function Guide:CountKill(xp, quest)
    local step = route and state and route.steps[state.step]
    if not step or not (step.fx or step.fk) or quest then return end
    local farm = state.farm
    if not farm or farm.step ~= state.step then
        farm = { step = state.step, xp = 0, kills = 0 }
        state.farm = farm
    end
    farm.xp = (farm.xp or 0) + math.max(0, xp or 0)
    farm.kills = (farm.kills or 0) + 1
    self:Refresh()
end

function Guide:Go(n)
    if not route then return end
    state.step = math.max(1, math.min(n, #route.steps + 1))
    -- Arrived on a group done already: it stays shown until the player moves on.
    arrivedDone = false
    if route.steps[state.step] then
        local first, last = GroupOf(state.step)
        arrivedDone = true
        for i = first, math.min(last, #route.steps) do
            local s = route.steps[i]
            if not s.bg and not IsDone(s, i) then arrivedDone = false end
        end
    end
    waypointStep, pointed, detour = nil, nil, nil
    self:Refresh()
end

--- Whether the guide still takes this quest: it has a step accepting it that is not done (not
--- marked by hand, not left behind, no exclusive alternative taken). The quests it abandons,
--- and the others, are not.
function Guide:WantsQuest(questID)
    local at = route and questID and acceptIndex[questID]
    if not at then return false end
    -- Offered for a book in the bags: taken at its turn-in.
    local step = route.steps[at]
    if step.hd and Held(step) then
        return not QuestLog.IsOnQuest(questID) and not QuestLog.IsQuestFlaggedCompleted(questID)
    end
    return not IsDone(step, at)
end

--- Whether accepting this quest starts an escort or an event (the guide's step says so).
function Guide:IsEscort(questID)
    local at = route and questID and acceptIndex[questID]
    return at ~= nil and route.steps[at].es == true
end

--- Fields of the guide state that belong to the route in use: the step shown, the steps
--- marked by their index and the quests marked done by hand.
local PROGRESS = { "step", "marks", "skippedQuests", "handedIn", "player" }

--- Progress is kept per route: another guide starts from its first step with nothing marked,
--- coming back to a guide finds where it was. A new version of the same guide keeps the
--- quests marked by hand, not the steps marked by index (its steps moved).
local function SwitchProgress(name)
    local r = name and FG.Routes and FG.Routes[name]
    local version = r and string.format("%s:%d", tostring(r.time), #r.steps) or nil
    if state.route ~= name then
        state.saved = state.saved or {}
        if state.route then
            local keep = { version = state.version }
            for _, k in ipairs(PROGRESS) do
                keep[k] = state[k]
            end
            state.saved[state.route] = keep
        end
        local back = name and state.saved[name] or {}
        if name then state.saved[name] = nil end
        for _, k in ipairs(PROGRESS) do
            state[k] = back[k]
        end
        state.version = back.version
    end
    -- Saved before versions were tracked: taken as the same version.
    if state.version and state.version ~= version then
        state.marks = {}
        state.step = 1 -- its steps moved
    end
    state.version = version
    state.step = state.step or 1
    state.marks = state.marks or {}
    state.skippedQuests = state.skippedQuests or {}
    state.handedIn = state.handedIn or {}
end

--- The quests taken by the built-in guides that lead to guide `name` (through their `next`).
local function PlanBefore(name)
    wipe(plannedBefore)
    if not (route and route.builtin and FG.Routes) then return end
    local seen, queue = { [name] = true }, { name }
    while #queue > 0 do
        local target = table.remove(queue)
        for other, r in pairs(FG.Routes) do
            if r.builtin and r.next == target and not seen[other] then
                seen[other] = true
                table.insert(queue, other)
                for _, s in ipairs(r.steps or {}) do
                    if s.k == "accept" and s.q then plannedBefore[s.q] = true end
                end
            end
        end
    end
end

local function UseRoute(name)
    route = FG.Routes and FG.Routes[name]
    name = route and name or nil
    SwitchProgress(name)
    state.route = name
    -- A group guide: as this player follows it.
    route = FG.Group:Use(route, state)
    wipe(acceptIndex)
    wipe(turninIndex)
    wipe(objectiveQuests)
    wipe(childQuests)
    wipe(questMobs)
    wipe(wasDone)
    for i, s in ipairs(route and route.steps or {}) do
        if s.k == "objective" then
            local mobs = s.mi or {}
            if s.e == "npc" and s.id then mobs = { s.id, unpack(mobs) } end
            for _, npc in ipairs(mobs) do
                questMobs[npc] = questMobs[npc] or {}
                table.insert(questMobs[npc], i)
            end
        end
        if s.q then
            if s.k == "accept" and not acceptIndex[s.q] then acceptIndex[s.q] = i end
            if s.k == "turnin" and not turninIndex[s.q] then turninIndex[s.q] = i end
            if s.k == "objective" then objectiveQuests[s.q] = true end
            if s.cq then childQuests[s.cq] = true end
        end
    end
    PlanBefore(name)
    BuildGroups()
end

--- The guide a character follows without having chosen one: the only guide made for its race
--- and class (the app's or imported, else built into the addon); else the one an older app
--- assigned to it (FG.Assignments); else none.
local function AutoRoute()
    local routes = FG.Routes or {}
    for _, builtin in ipairs({ false, true }) do
        local found, several
        for name, r in pairs(routes) do
            if not r.builtin == not builtin and FG.Import.Fits(r) then
                several = found ~= nil
                found = found or name
                if several then break end
            end
        end
        if found and not several then return found end
        if found then break end
    end
    local assigned = FG.Assignments and FG.Assignments[FG:CharacterKey()]
    if assigned and routes[assigned] then return assigned end
end

--- The guide the character chose (kept in its state), while it is there; else the automatic one.
local function PickRoute()
    if state.route and FG.Routes and FG.Routes[state.route] then return state.route end
    return AutoRoute()
end

--- Follow the guide chosen for the character again, or the automatic one when it is gone.
function Guide:FollowChoice()
    UseRoute(PickRoute())
    self:Resync()
end

--- The character follows the guide `name` from now on (nil: back to the automatic choice).
function Guide:Choose(name)
    if not state then return end
    UseRoute(name)
    if not name then UseRoute(PickRoute()) end
    self:Resync()
    FG.Options:Refresh()
end

--- The name of the guide followed, nil when none.
function Guide:RouteName() return route and state.route end

-- Tabs (Tabs.lua): the guides the character has open, each with its own progress (SwitchProgress).

--- Guides open at most; opening another closes the oldest one not followed.
local MAX_TABS = 6

--- The guides open in tabs (names, in the order opened), the one followed among them; those gone
--- (deleted) are left out.
function Guide:Tabs()
    if not state then return {} end
    local out, seen = {}, {}
    for _, name in ipairs(type(state.tabs) == "table" and state.tabs or {}) do
        if FG.Routes and FG.Routes[name] and not seen[name] then
            out[#out + 1], seen[name] = name, true
        end
    end
    local current = self:RouteName()
    if current and not seen[current] then out[#out + 1] = current end
    while #out > MAX_TABS do
        for i, name in ipairs(out) do
            if name ~= current then
                table.remove(out, i)
                break
            end
        end
    end
    state.tabs = out
    return out
end

--- Where the character is in the guide `name`: the step it is at (nil when never opened), the
--- guide's step count.
function Guide:Progress(name)
    local r = FG.Routes and FG.Routes[name]
    if not r or not state then return nil, r and #r.steps or 0 end
    if name == self:RouteName() then return state.step, #r.steps end
    local saved = type(state.saved) == "table" and state.saved[name]
    return saved and saved.step, #r.steps
end

--- Close the tab of the guide `name`. Closing the guide followed follows the tab beside it (none
--- left: the automatic choice).
function Guide:CloseTab(name)
    local tabs = self:Tabs()
    for i, n in ipairs(tabs) do
        if n == name then
            table.remove(tabs, i)
            if name == self:RouteName() then
                self:Choose(tabs[i] or tabs[i - 1])
            else
                self:Refresh()
            end
            return
        end
    end
end

FG:On("PLAYER_LOGIN", function()
    local char = PathwrightDB.characters[FG:CharacterKey()]
    char.guide = char.guide or { step = 1 }
    state = char.guide
    state.shown = nil -- moved to settings in 0.2
    state.flightLearned = nil -- replaced by marks in 0.3
    UseRoute(PickRoute())
    FG.Card:Create(state)
    if FG.Mini then FG.Mini:Create(state) end
    for _, key in ipairs({ "guideMode", "nextTab", "questPanel", "compassShown", "arrowShown" }) do
        FG:OnSetting(key, function() Guide:Refresh() end)
    end
    -- Waiting for the party on objectives, turned on or off: the step held moves on, or holds.
    FG:OnSetting("partyWait", function() Guide:Advance() end)
    -- However the guide is shown (key binding, options, slash command), ask for what is missing.
    FG:OnSetting("guideShown", function(shown)
        Guide:Refresh()
        if shown then Guide:AskMissing() end
    end)
    -- Any other setting chosen in the options shows at once.
    FG:OnSetting("*", function(key)
        if key ~= "uiShown" and key ~= "scale" then Guide:Refresh() end
    end)
    -- Hidden: the game's map pin goes too, and comes back with the guide.
    FG:OnSetting("uiShown", function(shown)
        if not shown and waypointStep and C_Map.ClearUserWaypoint then C_Map.ClearUserWaypoint() end
        waypointStep = nil
        Guide:Refresh()
        if shown then Guide:AskMissing() end
    end)
    FG:OnSetting("waypoints", function(on)
        waypointStep = nil
        if on then
            Guide:Refresh()
        elseif C_Map.ClearUserWaypoint then
            C_Map.ClearUserWaypoint()
        end
    end)
    Guide:Resync(true)
    C_Timer.NewTicker(1, function()
        FG:Try("guide tick", Guide.Advance, Guide)
        FG:Try("group tick", FG.Group.Tick, FG.Group, Guide:OwnStep())
    end)
end)

-- Visits are done when the matching window opens while the step is on screen.
local function Mark(kind)
    if not route then return end
    for _, index in ipairs(CurrentGroup()) do
        if route.steps[index].k == kind then state.marks[index] = true end
    end
end
FG:On("TAXIMAP_OPENED", function() Mark("flight_master") end)
FG:On("TRAINER_SHOW", function() Mark(IsTradeskillTrainer() and "profession" or "train") end)
FG:On("HEARTHSTONE_BOUND", function() Mark("bind") end)
FG:On("MERCHANT_SHOW", function() Mark("sell") end)
FG:On("QUEST_TURNED_IN", function(questID)
    if state and childQuests[questID] then state.handedIn[questID] = true end
end)

-- Dungeon steps: done once we entered the instance and came back out.
local function TrackInstance()
    if not route then return end
    local index = state.step
    local step = route.steps[index]
    if not step or step.k ~= "dungeon" then return end
    if IsInInstance() then
        state.marks[index] = "inside"
    elseif state.marks[index] == "inside" then
        state.marks[index] = true
    end
end
-- The boxes' size and visibility held during combat (see `FG.CanLayout`).
FG:On("PLAYER_REGEN_ENABLED", function() Guide:Refresh() end)
FG:On("PLAYER_ENTERING_WORLD", TrackInstance)
FG:On("ZONE_CHANGED_NEW_AREA", TrackInstance)

-- XP of the kills, for the mobs on the way. The XP is read on the character's XP bar (UnitXP:
-- readable on every client, rested bonus included); a gain is a kill's when a kill is seen
-- within PAIR_WINDOW of it, before or after: PARTY_KILL by the character or its pet (it gives
-- the mob, unless its GUID is secret), or the game's kill XP message (kills shared in a group).
-- Quest turn-ins, discoveries... come without one: not counted; a turn-in's XP is also taken
-- off a gain it shares with a kill. Gains are settled once that window has passed, so that the
-- signals of a kill (in any order) have all arrived.
local PAIR_WINDOW = 1
local SAME_KILL = 0.5 -- the PARTY_KILL and the XP message of one kill
local kills = {} -- { at, party, chat, quest, used }
local gains = {} -- { at, xp }
local turnins = {} -- { at, xp }: XP of the quests turned in, left to take off the gains
local lastXP -- { level, xp, max }
local settling = false

local Settle
local function SettleLater()
    if settling or not (C_Timer and C_Timer.After) then return end
    settling = true
    C_Timer.After(PAIR_WINDOW, function() FG:Try("farm XP", Settle) end)
end

--- Pair the gains old enough with the kills around them (the first one each), forget the old
--- kills.
function Settle()
    settling = false
    local now = GetTime()
    while gains[1] and now - gains[1].at >= PAIR_WINDOW do
        local gain = table.remove(gains, 1)
        for _, t in ipairs(turnins) do
            if math.abs(t.at - gain.at) <= PAIR_WINDOW then
                local quest = math.min(t.xp, gain.xp)
                t.xp, gain.xp = t.xp - quest, gain.xp - quest
            end
        end
        for _, k in ipairs(kills) do
            if gain.xp <= 0 then break end
            if not k.used and math.abs(k.at - gain.at) <= PAIR_WINDOW then
                k.used = true
                Guide:CountKill(gain.xp, k.quest)
                break
            end
        end
    end
    for _, list in ipairs({ kills, turnins }) do
        for i = #list, 1, -1 do
            if now - list[i].at > 2 * PAIR_WINDOW then table.remove(list, i) end
        end
    end
    if gains[1] or kills[1] or turnins[1] then SettleLater() end
end

--- A kill seen (`party`: by PARTY_KILL, else by the XP message): one entry per kill, the two
--- signals of the same kill merged.
local function KillSeen(party, quest)
    local now = GetTime()
    for _, k in ipairs(kills) do
        if
            math.abs(now - k.at) <= SAME_KILL
            and (party and k.chat and not k.party or not party and k.party and not k.chat)
        then
            if party then
                k.party, k.quest = true, quest
            else
                k.chat = true
            end
            return
        end
    end
    table.insert(kills, { at = now, party = party, chat = not party, quest = quest })
    SettleLater()
end

FG:On("PARTY_KILL", function(attackerGUID, targetGUID)
    local source, dest = FG.Readable(attackerGUID), FG.Readable(targetGUID)
    if not source or (source ~= FG.Readable(UnitGUID("player")) and source ~= FG.Readable(UnitGUID("pet"))) then
        return
    end
    if dest and not dest:find("^Creature") then return end
    -- Judged now: the quest log may count this very kill a moment later.
    local _, npc = FG.ParseGUID(dest)
    KillSeen(true, route and QuestMob(npc) or false)
end)

FG:On("CHAT_MSG_COMBAT_XP_GAIN", function(msg)
    if FG.IsKillXP and FG.IsKillXP(msg) then KillSeen(false, false) end
end)

FG:On("QUEST_TURNED_IN", function(_, xpReward)
    local xp = FG.Readable(xpReward)
    if type(xp) ~= "number" or xp <= 0 then return end
    table.insert(turnins, { at = GetTime(), xp = xp })
    SettleLater()
end)

--- XP gained since the last reading, across a level up.
local function ReadXP()
    local level = FG.Readable(UnitLevel("player"))
    local xp, max = FG.Readable(UnitXP("player")), FG.Readable(UnitXPMax("player"))
    if not level or not xp or not max then return 0 end
    local last = lastXP
    lastXP = { level = level, xp = xp, max = max }
    if not last then return 0 end
    if level > last.level or (level == last.level and xp < last.xp) then
        -- The level may still read the old one right after a level up.
        lastXP.level = math.max(level, last.level + 1)
        return level <= last.level + 1 and last.max - last.xp + xp or 0
    end
    return level == last.level and xp - last.xp or 0
end

FG:On("PLAYER_ENTERING_WORLD", function()
    lastXP = nil
    ReadXP()
end)

FG:On("PLAYER_XP_UPDATE", function(unit)
    if unit and unit ~= "player" then return end
    local gained = ReadXP()
    if gained <= 0 then return end
    table.insert(gains, { at = GetTime(), xp = gained })
    SettleLater()
end)

-- The quest log updates in bursts (several a second while looting): one advance after them.
local advancing = false
FG:On("QUEST_LOG_UPDATE", function()
    if advancing then return end
    advancing = true
    C_Timer.After(0.2, function()
        advancing = false
        FG:Try("guide", Guide.Advance, Guide)
    end)
end)

for _, event in ipairs({
    "QUEST_ACCEPTED",
    "QUEST_TURNED_IN",
    "QUEST_REMOVED",
    "PLAYER_LEVEL_UP",
    "PLAYER_CONTROL_LOST",
    "TAXIMAP_OPENED",
    "ZONE_CHANGED_NEW_AREA",
    "TRAINER_SHOW",
    "HEARTHSTONE_BOUND",
    "SKILL_LINES_CHANGED",
    -- An item looted: a book for the library is its quest's accept.
    "BAG_UPDATE_DELAYED",
}) do
    FG:On(event, function() Guide:Advance() end)
end

--- Slash commands of the guide (called from Core.lua).
--- Point at the next place of the current step's mobs ("Next spot", a key binding).
function Guide:NextSpot()
    local places = self:SpotPlaces()
    if not places then return FG:Print(L.noSpot) end
    NextSpot(places)
    self:Refresh()
end

--- Route followed by the character (nil when none).
function Guide:Route() return route end

--- Saved per-character guide state (also holds the tracker position).
function Guide:State() return state end

-- Kept apart for each mode (the card and the strip have their own places already).
local LAYOUT = { "trackerPoint", "compassWidth", "compassScale" }

--- The places and sizes of the windows shown in the current mode: moving one in a mode leaves
--- the other mode as it was. Nil before the login.
function Guide:Layout()
    if not state then return nil end
    local mode = FG:Get("guideMode") == "minimal" and "minimal" or "full"
    if not state.layout then
        -- Kept for both modes by older versions: they stay with the mode shown, the compass's place
        -- (only used by the full guide) with the full one.
        state.layout = { full = { compassPoint = state.compassPoint }, minimal = {} }
        state.compassPoint = nil
        for _, k in ipairs(LAYOUT) do
            state.layout[mode][k], state[k] = state[k], nil
        end
    end
    return state.layout[mode]
end

--- The steps of the current tasks (indexes in the route), none without a route.
function Guide:CurrentSteps()
    if not route or not state or not route.steps[state.step] then return nil end
    return CurrentGroup()
end

--- For each quest, its next step in the route from the current position: { index, k, n }.
function Guide:NextStepByQuest()
    local out = {}
    if not route or not state then return out end
    -- Background objectives left behind and not done yet: in progress along the way.
    for i = 1, math.min(state.step - 1, #route.steps) do
        local s = route.steps[i]
        if s.bg and not s.tr and not out[s.q] and QuestLog.IsOnQuest(s.q) and not IsDone(s, i) then
            out[s.q] = { index = i, k = s.k, n = s.n, bg = true }
        end
    end
    for i = state.step, #route.steps do
        local s = route.steps[i]
        if s.q and not out[s.q] and not IsDone(s, i) then out[s.q] = { index = i, k = s.k, n = s.n } end
    end
    -- Quests already behind us in the route still belong to it.
    for i = 1, math.min(state.step - 1, #route.steps) do
        local s = route.steps[i]
        if s.q and not out[s.q] then out[s.q] = { index = i, k = s.k, n = s.n } end
    end
    return out
end

--- Point the compass and the waypoint at a step until it is done (or another step is picked).
--- The game's waypoint is set again even for the step already pointed at: something else may
--- have moved or cleared it.
function Guide:PointToStep(index)
    local step = route and route.steps[index]
    if not step or not step.m then return end
    pointed, detour, waypointStep = index, nil, nil
    self:Refresh()
end

--- Point the compass and the waypoint (Shortest Path Forever when linked) at a place of the
--- compass (`Nearby:Around`) until the character is there, or a step is picked.
function Guide:PointToPlace(place)
    if not place or not place.m then return end
    detour = place
    self:Refresh()
end

--- Point the compass at a quest's next step.
function Guide:PointToQuest(questID)
    local next = self:NextStepByQuest()[questID]
    if next then self:PointToStep(next.index) end
end

--- Mark a step as already done by hand (its whole quest for quest steps), or undo it.
function Guide:ToggleSkip(index)
    local step = route and route.steps[index]
    if not step then return end
    if step.q then
        local name = QuestTitle(step) or step.n or tostring(step.q)
        if state.skippedQuests[step.q] then
            state.skippedQuests[step.q] = nil
            FG:Print(L.unskipped, name)
        else
            state.skippedQuests[step.q] = true
            lastMark = { route = route, q = step.q }
            FG:Print(L.skipped, name)
        end
    else
        state.marks[index] = state.marks[index] ~= "skip" and "skip" or nil
        if state.marks[index] then lastMark = { route = route, index = index } end
        FG:Print(L.stepSkipped)
    end
    FG.Group:MarksChanged()
    -- Back to the first step not done (an undone quest may be behind us).
    self:Resync()
end

--- Items the guide still has to buy (`by` steps of quests not turned in nor skipped, up to a few
--- levels ahead): item ID -> how many the bags should hold.
function Guide:Purchases()
    local out = {}
    if not route or not state then return out end
    local level = UnitLevel("player")
    for i, s in ipairs(route.steps) do
        if
            s.by
            and s.id
            and s.q
            and (s.lvl or 0) <= level + 3
            and not state.skippedQuests[s.q]
            and not QuestLog.IsQuestFlaggedCompleted(s.q)
            and not IsDone(s, i)
        then
            out[s.id] = math.max(out[s.id] or 0, s.c or 1)
        end
    end
    return out
end

--- The last step or quest marked as done by hand, while it still is (nil when none).
local function LastMark()
    if not lastMark or lastMark.route ~= route or not state then return nil end
    -- Several at once (a dungeon left aside): while one of them still is.
    if lastMark.many then
        for _, m in ipairs(lastMark.many) do
            if m.q and state.skippedQuests[m.q] or m.index and state.marks[m.index] == "skip" then return lastMark end
        end
        return nil
    end
    if lastMark.q and state.skippedQuests[lastMark.q] then return lastMark end
    if lastMark.index and state.marks[lastMark.index] == "skip" then return lastMark end
    return nil
end

--- Undo the last step or quest marked as done by hand ("Undo the last mark", a key binding).
function Guide:UndoLastMark()
    local mark = LastMark()
    lastMark = nil
    if not mark then return end
    if mark.many then
        for _, m in ipairs(mark.many) do
            if m.q then
                state.skippedQuests[m.q] = nil
            elseif state.marks[m.index] == "skip" then
                state.marks[m.index] = nil
            end
        end
        FG:Print(L.stepUnskipped)
    elseif mark.q then
        state.skippedQuests[mark.q] = nil
        local step
        for _, s in ipairs(route.steps) do
            if s.q == mark.q then
                step = s
                break
            end
        end
        FG:Print(L.unskipped, step and (QuestTitle(step) or step.n) or tostring(mark.q))
    else
        state.marks[mark.index] = nil
        FG:Print(L.stepUnskipped)
    end
    FG.Group:MarksChanged()
    self:Resync()
end

--- Mark the current step as done by hand, or undo it (a key binding).
function Guide:SkipCurrent()
    if route and state then self:ToggleSkip(state.step) end
end

--- Hide the guide, or show it again (a key binding; the setting, saved).
--- Ask the party about the shown objective steps whose quest has no member data (once per
--- quest until the roster changes; Party:Ask still throttles). Called on events only, never
--- from a redraw.
function Guide:AskMissing()
    if
        not FG.Party
        or not FG.Party.AskFor
        or not route
        or not state
        or not FG:Get("guideShown")
        or not FG:Get("uiShown")
    then
        return
    end
    for _, index in ipairs(CurrentGroup()) do
        local step = route.steps[index]
        if step and step.k == "objective" and step.q and QuestLog.IsOnQuest(step.q) then
            local o, at = FindObjectiveIndex(step)
            local members = at and FG.Party:Members(step.q, at, o and o.numRequired)
            if at and not (members and members[1]) then FG.Party:AskFor(step.q) end
        end
    end
end

FG:On("QUEST_LOG_UPDATE", function() Guide:AskMissing() end)

function Guide:ToggleShown() FG:Save("guideShown", not FG:Get("guideShown")) end

-- The key bindings (Bindings.xml, the game's key bindings: Pathwright). What they do while playing
-- is not in the addon's options.
-- Their own category ("Pathwright", Bindings.xml), a header per group.
BINDING_HEADER_PATHWRIGHT = T("Guide")
BINDING_HEADER_PATHWRIGHTTOOLSTRIP = T("Toolstrip")
for i = 1, 5 do
    _G["BINDING_NAME_CLICK PWStrip" .. i .. ":LeftButton"] = string.format(T("Toolstrip button %d"), i)
end
BINDING_NAME_PATHWRIGHT_NEXT = T("Next step")
BINDING_NAME_PATHWRIGHT_PREV = T("Previous step")
BINDING_NAME_PATHWRIGHT_SKIP = T("Mark this step as done")
BINDING_NAME_PATHWRIGHT_UNDO = T("Undo the last mark")
BINDING_NAME_PATHWRIGHT_SPOT = T("Next spot")
BINDING_NAME_PATHWRIGHT_MODE = T("Full or minimal guide")
BINDING_NAME_PATHWRIGHT_GUIDE = T("Show or hide the guide")
BINDING_NAME_PATHWRIGHT_UI = T("Show or hide all the addon's windows")
BINDING_NAME_PATHWRIGHT_TIME = T("Time per level (in the chat)")
BINDING_NAME_PATHWRIGHT_OPTIONS = T("Pathwright options")
BINDING_NAME_PATHWRIGHT_GUIDES = T("Guide browser")

--- Index of the step shown (for the tracker).
function Guide:CurrentStep() return state and state.step or 1 end

--- The first step we have not done ourselves, past those the guide waits on for the other
--- players of a group (what the party is told).
function Guide:OwnStep()
    if not route or not state then return nil end
    local i = state.step
    while route.steps[i] and (route.steps[i].bg or IsDone(route.steps[i], i)) do
        i = i + 1
    end
    return i
end

--- The guide's frame shown (full card or minimal strip).
function Guide:Box()
    local ui = self:UI()
    return ui and ui:Frame()
end

--- The kinds of steps: { icon, color, label }; OTHER for a kind not among them.
Guide.KINDS = KINDS
Guide.OTHER = OTHER
Guide.NoteMark = NoteMark
Guide.L = L
