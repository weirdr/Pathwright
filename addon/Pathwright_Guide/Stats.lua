-- Quest stats: how long each quest's objectives take you, how often its items drop for you, a
-- fantasy score for each quest you hand in, and a leaderboard with your friends and your guild.
--
-- Which quests count: those with something to count (kills, items, objects to use), and the
-- escorts (StatsData.lua lists them). A delivery, a talk, an exploration: no score. Each quest
-- once per character; its clock stops when its objectives are complete and its score is final
-- when it is handed in. Abandoned and taken again, it goes on with the same record: the time,
-- the kills and the deaths of every attempt add up.
--
-- Score = (base + (speed + luck) x share - deaths) x color, never below 0 (Stats.Points, the
-- numbers in RULES):
--   base   40 + 1 for each count. The units of an item that drops in the world but that you did
--          not loot yourself (bought, traded, mailed) count for half.
--   speed  60 x par / your time, at most 150. Par: 20 s for each kill an objective asks, 20 s for
--          each mob killed for an item, 15 s for any other count.
--   luck   -40 to +60: the kills your drops took against the kills they take on average
--          (80 x (1 - yours / expected)). The average is that of the other players' records of
--          the same quest once they hold 20 kills, the game data's drop chance before that.
--   share  of the counts you made in the field while on the quest: speed and luck count for
--          that share only (9 of 10 items bought: a tenth).
--   deaths 15 each, on one quest: the one whose mob you were fighting, else an escort under way,
--          else the quest you last made progress on nearby.
--   color  of the quest for your level when its objectives complete: red 1.5, orange 1.25,
--          yellow 1, green 0.75, gray 0.5.
-- An escort: a flat 100 x color, less 15 for each death and each failed attempt.
--
-- Time: only while logged in and in the quest's area (within AREA_YARDS of a place where one of
-- its counts happened or a place the guide gives for its objectives), a ticker adding it every
-- TICK seconds, at most MAX_TICK at once. The time since the last kill, loot or count goes to
-- the quest of the next one: quests done together in one camp do not each pay for the others.
-- A quest's clock starts with the fight of its first kill: the first kill an objective counts,
-- or the first kill of a mob that drops its item (the game data's mobs; for an item it does not
-- know, the kills of a mob count from its first one once it has dropped the item).
--
-- Items: each unit of an item objective is one of: looted on the quest (full), looted before it
-- was taken (full base, no speed or luck: `spare` keeps what you loot that no quest wants yet),
-- got otherwise (half the base when the item drops in the world, the full base when nothing
-- drops it). An item bound when picked up cannot be bought: never counted as bought.
--
-- Records are facts, not scores: a finished record keeps its counts, kills, drops, seconds,
-- deaths and levels, and every client works the score out. A record is sealed (a hash of its
-- facts, the character's name and a constant): edited by hand, it no longer matches and is left
-- out. Scores earned before these rules (records without `v`) stay as they were.
--
-- Sharing (setting statsShare): your finished records go to your friends who have the addon and
-- to your guild, silently, as addon messages: online WoW friends (whispers), Battle.net friends
-- in this same game (game data), your party and your guild. Only messages from those players
-- are taken. The first record a player sends for a quest stays: another one for the same quest
-- is refused and the player marked; so is a record that cannot be (Stats.Plausible).
-- Messages (prefix PWStats, fields joined by "|"):
--   H|2|<total>|<quests>|<fingerprint>|<records>|<old total>|<old quests>|<class>|<level>   hello
--   S|<since>               send me your records handed in after <since> (time()), oldest first
--   F|<record>;<record>...  records: <quest>,<17 facts>,<seal> (Stats.Wire)
--   E|<more>|<cursor>       end of a page of records; more = 1: ask again from <cursor>
--   P|<player>|<records>|<fingerprint>   what I hold of a player we may both know
--   R|<since> and Q|...     the messages of version 1, still answered and read

local FG = Pathwright
local T = FG.T
local QuestLog = FG.QuestLog
local Readable = FG.Readable
local Stats = { now = time, clock = GetTime }
FG.Stats = Stats

local PREFIX = "PWStats"
local VERSION = 2
--- The numbers of the score (see the top of the file).
local RULES = {
    base = 40,
    speed = 60,
    speedMax = 150,
    killPar = 20,
    otherPar = 15,
    luck = 80,
    luckMin = -40,
    luckMax = 60,
    luckKills = 20,
    death = 15,
    bought = 0.5,
    escort = 100,
    fail = 15,
    color = { 1.5, 1.25, 1, 0.75, 0.5 },
}
Stats.RULES = RULES
--- Part of every seal: a record edited by hand no longer matches its own.
local PEPPER = "pathwright:stats:2"
--- Records sent in answer to one request (version 1: newest first; version 2: a page).
local MAX_SENT, PAGE = 150, 24
--- Messages waiting to be sent beyond which a request for records is left unanswered.
local QUEUE_MAX = 240
--- Seconds between two hellos to the same player, and between two rounds of hellos.
local HELLO_AGAIN, HELLO_EVERY = 60, 900
--- Seconds between two messages sent: the first ones of a burst, then the others.
local SEND_GAP, SEND_SLOW, BURST = 0.25, 1, 8
--- Yards from the quest's places within which its time counts; places closer than MERGE_YARDS to
--- one kept already are not kept again, at most MAX_PLACES of them.
local AREA_YARDS, MERGE_YARDS, MAX_PLACES = 300, 60, 16
--- Seconds between two additions of time, and the most one adds.
local TICK, MAX_TICK = 5, 10
--- The most the fight of a quest's first kill adds to its time.
local MAX_FIRST = 120
--- Mobs remembered for a quest (that drop its item, that its objectives count, that may).
local MAX_MOBS = 16
--- Seconds after an escort is taken, or after a quest's last progress, a death is still its own.
local ESCORT_WINDOW, LAST_WINDOW = 900, 600

local L = {
    drop = T("drop %d%%"),
    pts = T("%d pts"),
    yours = T("You: %s"),
    friends = T("Friends on this quest:"),
    board = T("Leaderboard"),
    you = T("you"),
    quests = T("%d quests"),
    avg = T("avg %d"),
    none = T("No friend with Pathwright seen yet: their scores show here once they are online."),
}

-- The game data ---------------------------------------------------------------------------------

local EMPTY = { p = 0, mask = 0, mobs = {} }
Stats.dataCache = {}

--- A quest's data (StatsData.lua): { p = drop rate expected (0: unknown), mask = its item
--- objectives that drop in the world, mobs = { [npc] = true } that drop its items }.
local function Data(questID)
    local d = Stats.dataCache[questID]
    if d then return d end
    local text = FG.StatsData and FG.StatsData.quests and FG.StatsData.quests[questID]
    if not text then return EMPTY end
    local p, mask, mobs = text:match("^(%d+);(%d+);(.*)$")
    d = { p = (tonumber(p) or 0) / 1000, mask = tonumber(mask) or 0, mobs = {} }
    for npc in (mobs or ""):gmatch("%d+") do
        d.mobs[tonumber(npc)] = true
    end
    Stats.dataCache[questID] = d
    return d
end
Stats.Data = Data

--- Whether the item objective `index` of a quest drops in the world.
local function Farmable(data, index) return math.floor(data.mask / 2 ^ (index - 1)) % 2 == 1 end

function Stats.IsEscort(questID)
    local list = FG.StatsData and FG.StatsData.escort
    return list ~= nil and list:find("|" .. questID .. "|", 1, true) ~= nil
end

-- Records ---------------------------------------------------------------------------------------

local function DB()
    PathwrightDB.stats = PathwrightDB.stats or {}
    local db = PathwrightDB.stats
    db.peers = db.peers or {}
    return db
end

function Stats:Char() return PathwrightDB and PathwrightDB.characters and PathwrightDB.characters[FG:CharacterKey()] end

--- This character's quest records: questID -> record.
---   Under way: v = 2, s (when its clock started), t (seconds), got (units looted on it, by
---   item), ki (mobs killed for its items), dr / io (units dropped by mobs / taken from
---   objects), de (deaths), f (failed attempts), area, src, mobs, pre, loot.
---   Objectives complete: e, lv, pl (the quest's level, yours), k, o, it (kills, other counts
---   and items asked), on, ea, ob, ou (item units looted on it, looted earlier, got otherwise
---   of an item that drops, of one that does not). x = 1: an escort.
---   Handed in: d, seal; only the facts stay.
---   Before these rules: no v; e and sc (its score then), or p (under way when first seen).
function Stats:Quests()
    local char = self:Char()
    if not char then return {} end
    char.quests = char.quests or {}
    return char.quests
end

--- Units looted that no quest wanted then, by item ID: they are farmed, not bought, when a
--- quest asks for them later.
function Stats:Spare()
    local char = self:Char()
    if not char then return {} end
    char.spare = char.spare or {}
    return char.spare
end

--- Seconds a record's objectives took, in its area (nil before it starts; running: so far).
function Stats.Seconds(rec)
    if not rec or not rec.s then return nil end
    return rec.t or 0
end

local function New(quests, questID)
    local rec = { v = 2 }
    quests[questID] = rec
    return rec
end

--- Whether a record holds nothing worth keeping (a quest abandoned before anything happened).
local function Blank(rec) return not (rec.s or rec.pre or rec.de or rec.ki or rec.got or rec.f or rec.x) end

--- Keep a mob in one of a record's sets (src, mobs), at most MAX_MOBS.
local function Learn(rec, set, npc)
    if not npc then return end
    local t = rec[set] or {}
    rec[set] = t
    if t[npc] then return end
    local n = 0
    for _ in pairs(t) do
        n = n + 1
    end
    if n < MAX_MOBS then t[npc] = true end
end

--- A record under way before these rules goes on under them: what it looted so far was looted.
local function Upgrade(rec)
    local corpses, drops = 0, 0
    for _, l in pairs(rec.loot or {}) do
        corpses, drops = corpses + (l.c or 0), drops + (l.d or 0)
    end
    rec.v, rec.old = 2, true
    rec.ki, rec.dr = corpses > 0 and corpses or nil, drops > 0 and drops or nil
    rec.de, rec.deaths, rec.kills, rec.items, rec.need = rec.deaths, nil, nil, nil, nil
end

-- The quest's area ------------------------------------------------------------------------------

--- Where the player is in the world: continent, x, y (yards); nil when unknown (an instance).
function Stats.where()
    if not C_Map or not C_Map.GetWorldPosFromMapPos then return nil end
    local map = C_Map.GetBestMapForUnit("player")
    local pos = map and C_Map.GetPlayerMapPosition(map, "player")
    if not pos then return nil end
    local continent, world = C_Map.GetWorldPosFromMapPos(map, pos)
    if not continent or not world then return nil end
    local x, y = world:GetXY()
    return Readable(continent), Readable(x), Readable(y)
end

--- A map place in the world: continent, x, y (yards).
local function World(m, x, y)
    if not (m and x and y and C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return nil end
    local continent, world = C_Map.GetWorldPosFromMapPos(m, CreateVector2D(x / 100, y / 100))
    if not continent or not world then return nil end
    local wx, wy = world:GetXY()
    return continent, wx, wy
end

--- Keep a place of the quest's area (world continent and yards).
function Stats.AddPlace(rec, c, x, y)
    if not (c and x and y) then return end
    rec.area = rec.area or {}
    for _, p in ipairs(rec.area) do
        if p[1] == c and (p[2] - x) ^ 2 + (p[3] - y) ^ 2 < MERGE_YARDS ^ 2 then return end
    end
    if #rec.area < MAX_PLACES then table.insert(rec.area, { c, math.floor(x), math.floor(y) }) end
end

--- Whether the player stands in a record's area (true when the place is unknown either way).
function Stats.InArea(rec)
    local c, x, y = Stats.where()
    if not (c and x and y) or not rec.area or not rec.area[1] then return true end
    for _, p in ipairs(rec.area) do
        if p[1] == c and (p[2] - x) ^ 2 + (p[3] - y) ^ 2 < AREA_YARDS ^ 2 then return true end
    end
    return false
end

-- Time ------------------------------------------------------------------------------------------

local lastTick -- clock of the last addition of time (nil before the first, after login)
--- Seconds in a quest's area since the last kill, loot or count of any quest: questID -> seconds.
--- They go to the quest of the next one (Stats:Credit).
local pend = {}
Stats.pend = pend
--- The counts seen last, questID -> { have by objective }; nil before the first look at the log.
local seen
--- The fight under way or the last one: { start, stop, npc (the target when it began) }.
local fight
--- The last kill by the character: { npc, at }; the last progress: { quest, at }.
local lastKill, lastProgress

local function InLog(questID) return seen == nil or seen[questID] ~= nil end

--- Add the time since the last tick: to the quests under way whose area the player is in, and
--- to the mobs that may yet prove to drop an item of a quest not started.
function Stats:Tick()
    local now = self.clock()
    local dt = lastTick and math.max(0, math.min(MAX_TICK, now - lastTick)) or 0
    lastTick = now
    if dt == 0 then return end
    for questID, rec in pairs(self:Quests()) do
        if rec.v == 2 and not rec.e and not rec.x and InLog(questID) then
            if rec.s then
                if self.InArea(rec) then pend[questID] = (pend[questID] or 0) + dt end
            else
                for _, p in pairs(rec.pre or {}) do
                    p.t = (p.t or 0) + dt
                end
            end
        end
    end
end

--- Seconds of the fight under way, or just over: the time of a quest's first kill.
local function FirstFight()
    if not fight then return 0 end
    local now = Stats.clock()
    if fight.stop and now - fight.stop > 3 then return 0 end
    return math.max(0, math.min(MAX_FIRST, (fight.stop or now) - fight.start))
end

--- The guide's places for a quest's objectives (its steps and their spots) in its area.
function Stats:SeedArea(questID, rec)
    local route = FG.Guide and FG.Guide.Route and FG.Guide:Route()
    for _, s in ipairs(route and route.steps or {}) do
        if s.q == questID and s.k == "objective" then
            self.AddPlace(rec, World(s.m, s.x, s.y))
            for _, p in ipairs(s.spots or {}) do
                self.AddPlace(rec, World(p.m, p.x, p.y))
            end
        end
    end
end

--- A kill, a loot or a count of these quests: the time since the last one is theirs, shared
--- when it is of several (a mob two quests count). A quest not started starts here, with the
--- time of the fight when `fought`.
function Stats:Credit(ids, fought)
    self:Tick()
    local quests, live, done = self:Quests(), {}, {}
    for _, questID in ipairs(ids) do
        local rec = quests[questID]
        if rec and rec.v == 2 and not rec.e and not rec.x and not done[questID] then
            done[questID] = true
            live[#live + 1] = questID
        end
    end
    local n = #live
    if n == 0 then return end
    local c, x, y = self.where()
    for _, questID in ipairs(live) do
        local rec = quests[questID]
        if not rec.s then
            rec.s, rec.t = self.now(), fought and FirstFight() / n or 0
            self:SeedArea(questID, rec)
        else
            rec.t = (rec.t or 0) + (pend[questID] or 0) / n
        end
        self.AddPlace(rec, c, x, y)
    end
    wipe(pend)
    lastProgress = { quest = live[1], at = self.clock() }
end

-- Objectives --------------------------------------------------------------------------------------

--- The item objectives still needed, by item name (lowercase): { quest, index }.
Stats.wanted = {}
--- The quests with an item objective still needed: questID -> true.
Stats.items = {}

--- The item of an objective's text ("Wolf Claw: 1/2"): lowercase, and as written.
local function ItemName(text)
    local name = (text or ""):gsub("%s*:?%s*%d+%s*/%s*%d+%s*$", ""):gsub("^%d+%s*/%s*%d+%s+", "")
    return name:lower(), name
end

--- An item by its name: its ID, and whether it binds when picked up (it cannot be bought).
local function ItemFacts(name)
    if not FG.ItemInfo or name == "" then return nil end
    local r = { pcall(FG.ItemInfo, name) }
    if not r[1] then return nil end
    local link, bind = Readable(r[3]), Readable(r[15])
    local id = type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
    return id, bind == 1 or bind == 4
end
Stats.ItemFacts = ItemFacts

--- The color of a quest of level `lv` for a character of level `pl`: 1 red, 2 orange, 3 yellow,
--- 4 green, 5 gray (the game's own thresholds; yellow when a level is unknown).
function Stats.Color(lv, pl)
    lv, pl = tonumber(lv) or 0, tonumber(pl) or 0
    if lv <= 0 or pl <= 0 then return 3 end
    local diff = lv - pl
    if diff >= 5 then return 1 end
    if diff >= 3 then return 2 end
    if diff >= -2 then return 3 end
    local gray
    if pl <= 5 then
        gray = 0
    elseif pl <= 39 then
        gray = pl - math.floor(pl / 10) - 5
    elseif pl <= 59 then
        gray = pl - math.floor(pl / 5) - 1
    else
        gray = pl - 9
    end
    return lv > gray and 4 or 5
end

--- A quest's objectives are complete: its counts, and how each unit of its items was got.
function Stats:Complete(questID, objectives, now)
    local rec = self:Quests()[questID]
    local data, spare = Data(questID), self:Spare()
    local k, o, it, on, ea, ob, ou = 0, 0, 0, 0, 0, 0, 0
    for index, obj in ipairs(objectives) do
        local need = tonumber(obj.need) or 0
        if obj.type == "monster" then
            k = k + need
        elseif obj.type == "item" then
            local name, written = ItemName(obj.text)
            local got = math.min(need, rec.got and rec.got[name] or 0)
            local id, bound = Stats.ItemFacts(written)
            local early = math.min(need - got, id and spare[id] or 0)
            if early > 0 then spare[id] = spare[id] > early and spare[id] - early or nil end
            local rest = need - got - early
            if rest > 0 and (bound or rec.old) then
                early, rest = early + rest, 0
            end
            if rest > 0 then
                if Farmable(data, index) or got > 0 or early > 0 or (rec.src and next(rec.src)) then
                    ob = ob + rest
                else
                    ou = ou + rest
                end
            end
            it, on, ea = it + need, on + got, ea + early
        else
            o = o + need
        end
    end
    rec.e = now
    rec.k, rec.o, rec.it, rec.on, rec.ea, rec.ob, rec.ou = k, o, it, on, ea, ob, ou
    rec.lv, rec.pl = tonumber(objectives.level) or 0, tonumber(Readable(UnitLevel("player"))) or 0
    if not rec.s then rec.s = now end
    rec.t = rec.t or 0
    pend[questID] = nil
end

--- An escort in the log: taken, failed, complete.
function Stats:Escort(questID, objectives, first, now)
    local quests = self:Quests()
    local rec = quests[questID]
    if rec and (rec.d or not rec.v) then return end
    if not rec then
        rec = New(quests, questID)
        rec.s = now
    elseif not first and not (seen and seen[questID]) then
        rec.s = now -- taken again
    end
    rec.x = 1
    if objectives.failed then
        if not rec.failed then rec.failed, rec.f = true, (rec.f or 0) + 1 end
    else
        rec.failed = nil
    end
    if objectives.complete then
        if not rec.e then
            rec.e = now
            rec.lv, rec.pl = tonumber(objectives.level) or 0, tonumber(Readable(UnitLevel("player"))) or 0
        end
    else
        rec.e = nil
    end
end

--- Apply a look at the quest log: `log` = questID -> list of { have, need, finished, type, text }
--- with its `level`, `complete` and `failed`. `first`: the first look (login, reload): counts
--- already there start nothing.
function Stats:Apply(log, first, now)
    now = now or self.now()
    local quests = self:Quests()
    local wanted, items = {}, {}
    local rises, fought, complete = {}, false, {}
    for questID, objectives in pairs(log) do
        local rec = quests[questID]
        if rec and not rec.v and not rec.e and not rec.p then Upgrade(rec) end
        local before = seen and seen[questID]
        if Stats.IsEscort(questID) then
            self:Escort(questID, objectives, first, now)
        elseif not (rec and (rec.d or (not rec.v and rec.e))) then
            local total, allDone, counts, rose = 0, #objectives > 0, 0, false
            for index, o in ipairs(objectives) do
                local need = tonumber(o.need) or 0
                local have = math.min(tonumber(o.have) or 0, need)
                total, counts = total + need, counts + have
                allDone = allDone and (o.finished == true or (need > 0 and have >= need))
                local was = before and before[index] or (first and have) or 0
                if have > was and not (rec and (rec.e or rec.p)) then
                    rec = rec or New(quests, questID)
                    rose = true
                    if o.type == "monster" then
                        fought = true
                        -- The mob killed a moment ago is one this quest counts (see Stats:Died).
                        if lastKill and self.clock() - lastKill.at <= 2 then Learn(rec, "mobs", lastKill.npc) end
                    end
                end
                if o.type == "item" and not (o.finished or have >= need) and o.text then
                    local name = ItemName(o.text)
                    if name ~= "" then
                        wanted[name] = { quest = questID, index = index }
                        items[questID] = true
                    end
                end
            end
            -- Under way already when first seen, without a record: no time, no score.
            if first and not rec and counts > 0 then
                rec = { p = true }
                quests[questID] = rec
            end
            if rec and rec.v == 2 then
                if rose then rises[#rises + 1] = questID end
                if allDone and total > 0 then
                    if not rec.e then complete[#complete + 1] = { id = questID, objectives = objectives } end
                elseif rec.e then
                    rec.e = nil -- an item lost since: its objectives are open again
                end
            end
        end
        local counts2 = {}
        for index, o in ipairs(objectives) do
            counts2[index] = tonumber(o.have) or 0
        end
        log[questID] = counts2
    end
    if rises[1] then self:Credit(rises, fought) end
    for _, c in ipairs(complete) do
        self:Complete(c.id, c.objectives, now)
    end
    -- Gone from the log: handed in (its score is final), or abandoned (its record goes on when
    -- it is taken again; one from before these rules is forgotten, as it was).
    for questID, rec in pairs(quests) do
        if seen and seen[questID] and not log[questID] then
            if rec.v == 2 and not rec.d then
                local flagged = QuestLog.IsQuestFlaggedCompleted and Readable(QuestLog.IsQuestFlaggedCompleted(questID))
                if flagged then self:TurnedIn(questID, now) end
                if not rec.d then
                    rec.e, rec.failed = nil, nil
                    pend[questID] = nil
                    if flagged or Blank(rec) then quests[questID] = nil end
                end
            elseif not rec.v and not rec.e then
                quests[questID] = nil
            end
        end
    end
    seen = log
    self.wanted, self.items = wanted, items
end

--- Read the quest log and apply it.
function Stats:Scan(first)
    if not QuestLog.GetQuestObjectives or not QuestLog.GetNumQuestLogEntries then return end
    local log = {}
    for i = 1, QuestLog.GetNumQuestLogEntries() do
        local info = QuestLog.GetInfo and QuestLog.GetInfo(i)
        local questID = info and not info.isHeader and Readable(info.questID)
        if questID and questID > 0 then
            local list = {
                level = Readable(info.level),
                complete = QuestLog.IsComplete and Readable(QuestLog.IsComplete(questID)) or nil,
                failed = QuestLog.IsFailed and Readable(QuestLog.IsFailed(questID)) or nil,
            }
            for index, o in ipairs(QuestLog.GetQuestObjectives(questID) or {}) do
                list[index] = {
                    have = Readable(o.numFulfilled),
                    need = Readable(o.numRequired),
                    finished = Readable(o.finished),
                    type = Readable(o.type),
                    text = Readable(o.text),
                }
            end
            log[questID] = list
        end
    end
    self:Apply(log, first)
end

-- Kills and loot ----------------------------------------------------------------------------------

local corpses, corpseCount = {}, 0 -- "guid:quest" counted already as a mob killed for the quest

--- Whether this corpse is yet to count for this quest (a kill and its loot are one mob).
local function Uncounted(guid, questID)
    if not guid then return true end
    local key = guid .. ":" .. questID
    if corpses[key] then return false end
    if corpseCount > 2000 then
        wipe(corpses)
        corpseCount = 0
    end
    corpses[key], corpseCount = true, corpseCount + 1
    return true
end

--- A mob killed by the character (or its pet). For each quest that still needs an item: a mob
--- that drops it counts, and its time is the quest's; when nothing is known to drop the item,
--- the mob is remembered, to count from this kill once it has dropped it.
function Stats:Kill(npc, guid)
    if not npc then return end
    self:Tick() -- the time up to this kill is counted before the kill is
    lastKill = { npc = npc, at = self.clock() }
    local quests, hit = self:Quests(), {}
    for questID in pairs(self.items) do
        local rec = quests[questID]
        if not (rec and (rec.e or rec.p or not rec.v)) then
            local known = Data(questID).mobs
            if known[npc] or (rec and rec.src and rec.src[npc]) then
                rec = rec or New(quests, questID)
                if Uncounted(guid, questID) then rec.ki = (rec.ki or 0) + 1 end
                hit[#hit + 1] = questID
            elseif not next(known) and not (rec and rec.src and next(rec.src)) then
                rec = rec or New(quests, questID)
                rec.pre = rec.pre or {}
                local p = rec.pre[npc]
                if not p then
                    local n = 0
                    for _ in pairs(rec.pre) do
                        n = n + 1
                    end
                    if n < MAX_MOBS then
                        p = { n = 0, s = self.now(), t = FirstFight() }
                        p.c, p.x, p.y = self.where()
                        rec.pre[npc] = p
                    end
                end
                if p and Uncounted(guid, questID) then p.n = p.n + 1 end
            end
        end
    end
    if hit[1] then self:Credit(hit, true) end
end

--- A mob has dropped a quest's item: it is one of its mobs, and its kills remembered so far
--- count (Stats:Kill), the quest's clock starting at the first of them.
local function Source(rec, npc)
    Learn(rec, "src", npc)
    local p = rec.pre and rec.pre[npc]
    if not p then return end
    rec.ki = (rec.ki or 0) + p.n
    if not rec.s then
        rec.s, rec.t = p.s, p.t or 0
        Stats.AddPlace(rec, p.c, p.x, p.y)
    end
    rec.pre[npc] = nil
    if not next(rec.pre) then rec.pre = nil end
end

--- Count what a loot window holds: `list` = corpses { npc, guid, kind ("object": not a mob),
--- items = { [lowercase name] = quantity }, ids = { [lowercase name] = item ID } }.
function Stats:Loot(list)
    local quests, spare = self:Quests(), self:Spare()
    -- What no quest wants now is kept: farmed, not bought, for a quest taken later.
    for _, corpse in ipairs(list) do
        for name, quantity in pairs(corpse.items) do
            local id = corpse.ids and corpse.ids[name]
            if id and not self.wanted[name] then spare[id] = (spare[id] or 0) + quantity end
        end
    end
    local hit, counted = {}, {}
    for name, w in pairs(self.wanted) do
        -- The loot window comes before the quest log counts the item: its record may start here.
        local rec = quests[w.quest]
        if not (rec and (rec.e or rec.p or not rec.v)) then
            local known = Data(w.quest).mobs
            for index, corpse in ipairs(list) do
                local has = corpse.items[name]
                local mob = corpse.kind ~= "object" and corpse.npc or nil
                if has then
                    rec = rec or New(quests, w.quest)
                    rec.got = rec.got or {}
                    rec.got[name] = (rec.got[name] or 0) + has
                    if mob then
                        rec.dr = (rec.dr or 0) + has
                        Source(rec, mob)
                    else
                        rec.io = (rec.io or 0) + has
                    end
                    hit[w.quest] = true
                end
                if mob and (known[mob] or (rec and rec.src and rec.src[mob])) then
                    rec = rec or New(quests, w.quest)
                    local key = index .. ":" .. w.quest
                    if not counted[key] then
                        counted[key] = true
                        if Uncounted(corpse.guid, w.quest) then rec.ki = (rec.ki or 0) + 1 end
                        hit[w.quest] = true
                    end
                    -- Of the corpses looted of its mobs, the share that had the item (the step's line).
                    rec.loot = rec.loot or {}
                    local l = rec.loot[name] or { c = 0, d = 0 }
                    rec.loot[name] = l
                    l.c = l.c + 1
                    if has then l.d = l.d + 1 end
                end
            end
        end
    end
    local ids = {}
    for questID in pairs(hit) do
        ids[#ids + 1] = questID
    end
    if ids[1] then self:Credit(ids, false) end
end

local looted, lootedCount = {}, 0 -- loot sources counted already (the window opened again)

--- Read the loot window (before fast loot takes it, Automation.lua calls this first).
function Stats:ReadLoot()
    if not GetLootSourceInfo or not GetNumLootItems then return end
    local byGuid, order = {}, {}
    for slot = 1, GetNumLootItems() do
        local link = GetLootSlotLink and Readable(GetLootSlotLink(slot))
        local name = type(link) == "string" and link:match("%[(.-)%]") or nil
        local id = type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
        local sources = { GetLootSourceInfo(slot) }
        for i = 1, #sources, 2 do
            local guid = Readable(sources[i])
            if guid and not looted[guid] then
                local kind, npc = FG.ParseGUID(guid)
                local corpse = byGuid[guid]
                if not corpse then
                    local what = kind == "npc" and "npc" or "object"
                    corpse = { npc = npc, guid = guid, kind = what, items = {}, ids = {} }
                    byGuid[guid] = corpse
                    order[#order + 1] = guid
                end
                if name then
                    corpse.items[name:lower()] = (tonumber(Readable(sources[i + 1])) or 1)
                    corpse.ids[name:lower()] = id
                end
            end
        end
    end
    local list = {}
    for _, guid in ipairs(order) do
        looted[guid] = true
        lootedCount = lootedCount + 1
        list[#list + 1] = byGuid[guid]
    end
    if lootedCount > 500 then
        wipe(looted)
        lootedCount = 0
    end
    if list[1] then self:Loot(list) end
end

--- The first time these rules run on a character: what its bags hold now was not bought under
--- them, so it is kept as looted (Stats:Spare).
function Stats:SeedSpare()
    local char = self:Char()
    if not char or char.spareSeeded or not (C_Container and C_Container.GetContainerNumSlots) then return end
    char.spareSeeded = true
    local spare = self:Spare()
    for bag = 0, 4 do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            local id = info and Readable(info.itemID)
            if id then spare[id] = (spare[id] or 0) + (tonumber(Readable(info.stackCount)) or 1) end
        end
    end
end

-- Deaths ------------------------------------------------------------------------------------------

--- The character died: on one quest only. The one whose mob it was fighting (the target when
--- the fight began), else an escort taken a moment ago, else the quest it last made progress
--- on, when that was lately and nearby. Returns that quest.
function Stats:Died()
    local quests = self:Quests()
    local function Open(questID)
        local rec = quests[questID]
        return rec and rec.v == 2 and not rec.e and not rec.d and InLog(questID) and rec or nil
    end
    local function Charge(questID, rec)
        rec.de = (rec.de or 0) + 1
        return questID
    end
    local npc = fight and fight.npc
    if npc then
        for questID in pairs(quests) do
            local rec = Open(questID)
            if
                rec
                and not rec.x
                and (
                    (rec.mobs and rec.mobs[npc])
                    or (rec.src and rec.src[npc])
                    or (rec.pre and rec.pre[npc])
                    or (self.items[questID] and Data(questID).mobs[npc])
                )
            then
                return Charge(questID, rec)
            end
        end
    end
    for questID in pairs(quests) do
        local rec = Open(questID)
        if rec and rec.x and rec.s and self.now() - rec.s <= ESCORT_WINDOW then return Charge(questID, rec) end
    end
    if lastProgress and self.clock() - lastProgress.at <= LAST_WINDOW then
        local rec = Open(lastProgress.quest)
        if rec and rec.s and self.InArea(rec) then return Charge(lastProgress.quest, rec) end
    end
    return nil
end

-- The score ---------------------------------------------------------------------------------------

--- The facts of a record, in the order they are sent (Stats.Wire).
local FIELDS = { "d", "t", "lv", "pl", "k", "o", "it", "on", "ea", "ob", "ou", "ki", "io", "dr", "de", "f", "x" }

--- A record as text: its quest and its facts, joined by ",", a zero left empty.
function Stats.Wire(questID, f)
    local parts = { tostring(questID) }
    for i, key in ipairs(FIELDS) do
        local v = math.floor((tonumber(f[key]) or 0) + 0.5)
        parts[i + 1] = v ~= 0 and tostring(v) or ""
    end
    return table.concat(parts, ",")
end

local parsed = setmetatable({}, { __mode = "k" })

--- A record read back from its text with its seal ("<wire>,<seal>"): its facts (and `q`, its
--- quest), the seal, the wire; nil when it is not one.
function Stats.Parse(text)
    if type(text) ~= "string" then return nil end
    local parts = { strsplit(",", text) }
    if #parts ~= #FIELDS + 2 then return nil end
    local f = { q = tonumber(parts[1]) }
    if not f.q or f.q <= 0 or f.q ~= math.floor(f.q) then return nil end
    for i, key in ipairs(FIELDS) do
        local raw = parts[i + 1]
        local v = raw == "" and 0 or tonumber(raw)
        if not v or v < 0 or v ~= math.floor(v) or v > 4294967295 then return nil end
        f[key] = v
    end
    local seal = parts[#parts]
    if not seal:match("^%x%x%x%x%x%x%x%x$") then return nil end
    return f, seal, text:sub(1, #text - 9)
end

--- The facts of a record kept as text (a friend's), read once.
local function Facts(text)
    local f = parsed[text]
    if f == nil then
        f = Stats.Parse(text) or false
        parsed[text] = f
    end
    return f or nil
end

--- FNV-1a over a text, 32 bits.
local function Hash(text)
    local h = 2166136261
    for i = 1, #text do
        h = bit.bxor(h, text:byte(i)) % 4294967296
        local lo = h % 65536
        local hi = (h - lo) / 65536
        h = ((hi * 16777619) % 65536 * 65536 + lo * 16777619) % 4294967296
    end
    return h
end

--- The seal of a record: of its text and its character's name.
function Stats.Seal(wire, name) return string.format("%08x", Hash(wire .. "|" .. (name or "") .. "|" .. PEPPER)) end

--- Whether a record can be: its item units add up, drops need kills, a kill takes a second,
--- it was not handed in tomorrow.
function Stats.Plausible(f, now)
    if f.d < 1000000000 or f.d > (now or time()) + 86400 then return false end
    if f.lv > 100 or f.pl > 100 or f.x > 1 then return false end
    if f.x == 1 then return true end
    if f.k + f.o + f.it < 1 then return false end
    if f.on + f.ea + f.ob + f.ou ~= f.it then return false end
    if f.on > f.dr + f.io then return false end
    if f.dr > 0 and f.ki < 1 then return false end
    if f.t < f.k + f.ki then return false end
    return true
end

--- The points of a record's facts. `rate`: the drop rate expected for its quest (nil: no luck);
--- `drops`: the items it holds as dropping nowhere have since been seen to drop. `out` (a table)
--- takes what the score is made of: base, speed, luck (may be negative), lost (to deaths and
--- failures), and rated (its luck was measured).
function Stats.Points(f, rate, drops, out)
    local R = RULES
    local mult = R.color[Stats.Color(f.lv, f.pl)]
    local deaths = R.death * (f.de or 0)
    local base, speed, luck, share, rated = 0, 0, 0, 1, false
    if (f.x or 0) ~= 0 then
        base, deaths = R.escort, deaths + R.fail * (f.f or 0)
    else
        local k, o, it = f.k or 0, f.o or 0, f.it or 0
        local n = k + o + it
        if n <= 0 then
            if out then out.base, out.speed, out.luck, out.lost, out.rated = 0, 0, 0, 0, false end
            return 0
        end
        local bought = (f.ob or 0) + (drops and (f.ou or 0) or 0)
        base = (R.base + n) * (1 - R.bought * bought / n)
        share = math.max(0, n - (f.ea or 0) - (f.ob or 0) - (f.ou or 0)) / n
        local ki, dr = f.ki or 0, f.dr or 0
        local par = R.killPar * (k + ki) + R.otherPar * (o + (f.io or 0))
        local seconds = f.t or 0
        if par > 0 then speed = seconds > 0 and math.min(R.speedMax, R.speed * par / seconds) or R.speed end
        if rate and rate > 0 and ki > 0 and dr > 0 then
            luck, rated = math.max(R.luckMin, math.min(R.luckMax, R.luck * (1 - ki * rate / dr))), true
        end
    end
    if out then
        out.base, out.speed, out.luck = base * mult, speed * share * mult, luck * share * mult
        out.lost, out.rated = deaths * mult, rated
    end
    return math.max(0, math.floor((base + (speed + luck) * share - deaths) * mult + 0.5))
end

--- What every record held says of each quest: questID -> { k = mobs killed for its items, d =
--- units dropped, farm = someone looted its items }. Kept until a record comes or goes.
function Stats:Shared()
    if self.shared then return self.shared end
    local sums = {}
    local function Add(questID, f)
        local s = sums[questID] or { k = 0, d = 0 }
        sums[questID] = s
        s.k, s.d = s.k + (f.ki or 0), s.d + (f.dr or 0)
        if (f.on or 0) + (f.ea or 0) > 0 then s.farm = true end
    end
    for questID, rec in pairs(self:Quests()) do
        if rec.v == 2 and rec.d and not rec.bad then Add(questID, rec) end
    end
    for _, peer in pairs(DB().peers) do
        if not peer.flag then
            for questID, text in pairs(peer.q or {}) do
                local f = type(text) == "string" and Facts(text)
                if f then Add(questID, f) end
            end
        end
    end
    self.shared = sums
    return sums
end

--- The score of a record of a quest (mine or a friend's facts); `held`: it is one of those
--- Stats:Shared adds up, so it is taken out of the average it is measured against.
function Stats:Score(f, questID, held, out)
    local s = self:Shared()[questID]
    local rate
    if s then
        local k, d = s.k - (held and f.ki or 0), s.d - (held and f.dr or 0)
        if k >= RULES.luckKills and d > 0 then rate = d / k end
    end
    if not rate then
        local p = Data(questID).p
        rate = p > 0 and p or nil
    end
    return Stats.Points(f, rate, s and s.farm, out)
end

--- A record's score as shown: before these rules the one it got then, else worked out.
local function Shown(self, questID, rec)
    if not rec.v then return rec.sc end
    if not rec.e then return nil end
    return self:Score(rec, questID, rec.d ~= nil)
end

--- My totals (this character): score and quests in all, then the records under these rules
--- and their fingerprint (the sum of their seals), then the score and quests from before them.
function Stats:Total()
    local total, count, records, mark, oldTotal, oldCount = 0, 0, 0, 0, 0, 0
    for questID, rec in pairs(self:Quests()) do
        if rec.v == 2 then
            if rec.d and not rec.bad then
                total, count, records = total + self:Score(rec, questID, true), count + 1, records + 1
                mark = (mark + (tonumber(rec.seal, 16) or 0)) % 4294967296
            end
        elseif rec.e and not rec.p then
            oldTotal, oldCount = oldTotal + (rec.sc or 0), oldCount + 1
        end
    end
    return total + oldTotal, count + oldCount, records, mark, oldTotal, oldCount
end

--- Drop rate of a record: share (0-1) over all its items, the corpses counted, nil without any.
function Stats.Rate(rec, item)
    local c, d = 0, 0
    for name, l in pairs(rec and rec.loot or {}) do
        if not item or name == item then
            c, d = c + (l.c or 0), d + (l.d or 0)
        end
    end
    if c == 0 then
        -- A record handed in keeps no corpses: its drops over the mobs killed for them.
        local kills, drops = rec and rec.ki or 0, rec and rec.dr or 0
        if item or kills <= 0 then return nil end
        return math.min(1, drops / kills), kills, drops
    end
    return d / c, c, d
end

local function MyName() return Readable(UnitName("player")) or "" end

--- A quest handed in: its record is final. Only its facts stay, sealed, and go to the friends.
function Stats:TurnedIn(questID, now)
    local rec = self:Quests()[questID]
    if not rec or rec.v ~= 2 or rec.d then return end
    if not rec.e then
        if not rec.x then return end
        rec.e = now or self.now()
        rec.lv, rec.pl = rec.lv or 0, tonumber(Readable(UnitLevel("player"))) or 0
    end
    rec.d = now or self.now()
    rec.t = math.floor((rec.t or 0) + 0.5)
    for _, key in ipairs({ "area", "src", "mobs", "pre", "got", "loot", "failed", "old", "s" }) do
        rec[key] = nil
    end
    rec.seal = Stats.Seal(Stats.Wire(questID, rec), MyName())
    pend[questID] = nil
    self.shared = nil
    self:Finished(questID, rec)
end

--- At login: a record handed in whose seal no longer matches its facts was edited: left out.
function Stats:Verify()
    local name = MyName()
    for questID, rec in pairs(self:Quests()) do
        if rec.v == 2 and rec.d then rec.bad = rec.seal ~= Stats.Seal(Stats.Wire(questID, rec), name) or nil end
    end
    self.shared = nil
end

-- What the guide shows ----------------------------------------------------------------------------

local function Clock(seconds)
    seconds = math.floor(seconds + 0.5)
    if seconds >= 3600 then
        return string.format("%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    end
    return string.format("%d:%02d", seconds / 60, seconds % 60)
end
Stats.Clock = Clock

--- The small line of a step: its quest's time (so far, or in the end), the drop rate of its
--- item, the score once its objectives are done. Nil when there is nothing yet (or stats are off).
function Stats:StepLine(step)
    if not FG:Get("questStats") or not step or not step.q then return nil end
    local rec = self:Quests()[step.q]
    if not rec or rec.p or rec.bad or not (rec.s or rec.e) then return nil end
    local parts = {}
    if step.e == "item" and step.n then
        local rate = self.Rate(rec, step.n:lower()) or (rec.d and self.Rate(rec))
        if rate then parts[#parts + 1] = string.format(L.drop, math.floor(rate * 100 + 0.5)) end
    end
    if not rec.x and (rec.s or rec.t) then parts[#parts + 1] = Clock(rec.t or 0) end
    local score = Shown(self, step.q, rec)
    if score then parts[#parts + 1] = string.format(L.pts, score) end
    if not parts[1] then return nil end
    return table.concat(parts, " • ")
end

--- Tooltip lines of a step's quest: mine, then the friends' best on it (by score).
function Stats:TooltipLines(step)
    if not FG:Get("questStats") or not step or not step.q then return nil end
    local lines = {}
    local mine = self:StepLine(step)
    if mine then lines[#lines + 1] = string.format(L.yours, mine) end
    local others = {}
    for name, peer in pairs(DB().peers) do
        local q = peer.q and peer.q[step.q]
        if type(q) == "table" then
            others[#others + 1] = { name = name, s = q.s or 0, t = q.t, r = q.r }
        elseif q and not peer.flag then
            local f = Facts(q)
            if f then
                local rate = f.ki > 0 and math.floor(math.min(1, f.dr / f.ki) * 100 + 0.5) or nil
                others[#others + 1] =
                    { name = name, s = self:Score(f, step.q, true), t = f.x == 0 and f.t or nil, r = rate }
            end
        end
    end
    table.sort(others, function(a, b) return a.s > b.s end)
    if others[1] then lines[#lines + 1] = L.friends end
    for i = 1, math.min(3, #others) do
        local o = others[i]
        local bits = { (o.name:gsub("%-.*", "")) }
        if o.t then bits[#bits + 1] = Clock(o.t) end
        if o.r then bits[#bits + 1] = string.format(L.drop, o.r) end
        bits[#bits + 1] = string.format(L.pts, o.s)
        lines[#lines + 1] = "  " .. table.concat(bits, " • ")
    end
    return lines[1] and lines or nil
end

-- Sharing with friends --------------------------------------------------------------------------

local function Me() return FG:CharacterKey():gsub("%s", "") end

--- A player's full name, "Name-Realm".
local function Full(name, realm)
    if not name then return nil end
    if not name:find("-", 1, true) then name = name .. "-" .. (realm or GetNormalizedRealmName() or "") end
    return (name:gsub("%s", ""))
end

--- A player's name alone: what a seal is made with.
local function Short(full) return (full:gsub("%-.*", "")) end

local guild -- the guild's members, { [full name] = { class, level } }; nil: to read again
local classTokens -- the game's class names in this language -> their tokens ("Voleur" -> "ROGUE")

--- A class as the game names it, whatever it gave: its token, or its name in this language.
local function ClassToken(class)
    if type(class) ~= "string" or class == "" then return nil end
    if RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then return class end
    if not classTokens then
        classTokens = {}
        for _, names in ipairs({ LOCALIZED_CLASS_NAMES_MALE or false, LOCALIZED_CLASS_NAMES_FEMALE or false }) do
            for token, name in pairs(names or {}) do
                if type(name) == "string" then classTokens[name] = token end
            end
        end
    end
    return classTokens[class]
end

local function Level(level)
    level = tonumber(level)
    return level and level > 0 and math.floor(level) or nil
end
local circle, circleAt -- Stats.Friends as read last, and when

--- Who we share with now: { whispers = { full names }, bnet = { gameAccountID = full name } }
--- (online WoW friends, Battle.net friends in this game), and everyone a message is taken from:
--- those, the party's members and the guild's.
function Stats.Friends()
    local now = Stats.clock()
    if circle and circleAt and now - circleAt < 2 and now >= circleAt then return circle end
    local out = { whispers = {}, bnet = {}, allowed = {}, friends = {}, guild = {}, class = {} }
    if C_FriendList and C_FriendList.GetNumFriends then
        for i = 1, C_FriendList.GetNumFriends() or 0 do
            local info = C_FriendList.GetFriendInfoByIndex(i)
            local name = info and Full(Readable(info.name))
            if name then
                out.allowed[name], out.friends[name] = true, true
                out.class[name] = { class = ClassToken(Readable(info.className)), level = Level(Readable(info.level)) }
                if Readable(info.connected) then out.whispers[#out.whispers + 1] = name end
            end
        end
    end
    if BNGetNumFriends and C_BattleNet and C_BattleNet.GetFriendNumGameAccounts then
        for i = 1, BNGetNumFriends() or 0 do
            for j = 1, C_BattleNet.GetFriendNumGameAccounts(i) or 0 do
                local g = C_BattleNet.GetFriendGameAccountInfo(i, j)
                local sameGame = g
                    and Readable(g.isOnline)
                    and g.clientProgram == (BNET_CLIENT_WOW or "WoW")
                    and (not WOW_PROJECT_ID or not g.wowProjectID or g.wowProjectID == WOW_PROJECT_ID)
                if sameGame and g.gameAccountID and g.characterName then
                    local name = Full(g.characterName, g.realmName)
                    out.bnet[g.gameAccountID] = name
                    out.allowed[name], out.friends[name] = true, true
                    out.class[name] = { class = ClassToken(g.className), level = Level(g.characterLevel) }
                end
            end
        end
    end
    for i = 1, GetNumSubgroupMembers and GetNumSubgroupMembers() or 0 do
        local name, realm = UnitName("party" .. i)
        name = Full(Readable(name), Readable(realm))
        if name then
            out.allowed[name], out.friends[name] = true, true
            local _, class = UnitClass("party" .. i)
            out.class[name] = { class = ClassToken(Readable(class)), level = Level(Readable(UnitLevel("party" .. i))) }
        end
    end
    if not guild then
        guild = {}
        if IsInGuild and IsInGuild() and GetNumGuildMembers and GetGuildRosterInfo then
            for i = 1, GetNumGuildMembers() or 0 do
                local member, _, _, level, _, _, _, _, _, _, class = GetGuildRosterInfo(i)
                local name = Full(Readable(member))
                if name then guild[name] = { class = ClassToken(Readable(class)), level = Level(Readable(level)) } end
            end
        end
    end
    for name, known in pairs(guild) do
        out.allowed[name], out.guild[name] = true, true
        out.class[name] = out.class[name] or known
    end
    circle, circleAt = out, now
    return out
end

--- The circle changed (a friend, the party, the guild's roster): read it again.
function Stats.Forget(roster)
    circle = nil
    if roster then guild = nil end
end

local queue, sending, burst = {}, false, 0

local function Flush()
    sending = false
    local m = table.remove(queue, 1)
    if not m then
        burst = 0
        return
    end
    local result
    if m.bnet and BNSendGameData then
        BNSendGameData(m.bnet, PREFIX, m.text)
    elseif m.channel and C_ChatInfo and C_ChatInfo.SendAddonMessage then
        result = C_ChatInfo.SendAddonMessage(PREFIX, m.text, m.channel, m.target)
    end
    -- Refused for now (the game limits addon messages): once more, later.
    local refused = result == false or (type(result) == "number" and result ~= 0)
    if refused and (m.tries or 0) < 5 then
        m.tries = (m.tries or 0) + 1
        table.insert(queue, 1, m)
    end
    burst = burst + 1
    if queue[1] and C_Timer and C_Timer.After then
        sending = true
        C_Timer.After(refused and 2 * SEND_SLOW or burst > BURST and SEND_SLOW or SEND_GAP, Flush)
    elseif queue[1] and not refused then
        Flush()
    else
        burst = 0
    end
end

local function Queue(m)
    if not FG:Get("statsShare") then return end
    queue[#queue + 1] = m
    if not sending then Flush() end
end

--- Send `text` to everyone we share with, or to `only` (a full name) when they are one of them.
function Stats:Send(text, only)
    local friends = self.Friends()
    if only then
        for id, name in pairs(friends.bnet) do
            if name == only then return Queue({ bnet = id, text = text }) end
        end
        if friends.allowed[only] then Queue({ channel = "WHISPER", target = only, text = text }) end
        return
    end
    for _, name in ipairs(friends.whispers) do
        Queue({ channel = "WHISPER", target = name, text = text })
    end
    for id in pairs(friends.bnet) do
        Queue({ bnet = id, text = text })
    end
    if IsInGroup and IsInGroup() and not IsInRaid() then Queue({ channel = "PARTY", text = text }) end
    if IsInGuild and IsInGuild() then Queue({ channel = "GUILD", text = text }) end
end

--- A record as version 1 sent it (a friend whose addon is older asks with R).
function Stats.Record(questID, rec)
    local rate = Stats.Rate(rec)
    return string.format(
        "Q|%d|%d|%s|%d|%d",
        questID,
        Stats.Seconds(rec) or rec.t or 0,
        rate and tostring(math.floor(rate * 100 + 0.5)) or "",
        Shown(Stats, questID, rec) or 0,
        rec.d or rec.e or 0
    )
end

--- A record handed in as it is sent: its text and its seal.
local function Sealed(questID, rec) return Stats.Wire(questID, rec) .. "," .. rec.seal end

function Stats:Hello(only, channel)
    local total, count, records, mark, oldTotal, oldCount = self:Total()
    local text = string.format("H|%d|%d|%d|%d|%d|%d|%d", VERSION, total, count, mark, records, oldTotal, oldCount)
    -- Who we are, for the board: class and level.
    text = text .. "|" .. (Stats.MyClass() or "") .. "|" .. (tonumber(Readable(UnitLevel("player"))) or 0)
    if channel then return Queue({ channel = channel, text = text }) end
    self:Send(text, only)
end

--- A quest handed in: tell the friends.
function Stats:Finished(questID, rec)
    self:Send("F|" .. Sealed(questID, rec))
    self:Hello()
end

--- What we hold of a player under these rules: how many records, and their fingerprint.
local function Held(peer)
    local n, mark = 0, 0
    for _, text in pairs(peer.q or {}) do
        if type(text) == "string" then
            n, mark = n + 1, (mark + (tonumber(text:sub(-8), 16) or 0)) % 4294967296
        end
    end
    return n, mark
end

local helloAt = {} -- full name (or "GUILD") -> when we last said hello to them
local asked = {} -- full name -> the hello ("records:fingerprint") we last asked records for
local gossip = {} -- full name -> true: what we hold of them changed, to tell our friends

--- Take one record a player sent: its seal must be theirs, it must be possible, and the first
--- one they sent for a quest stays.
function Stats:Take(sender, peer, text)
    local f, seal, wire = Stats.Parse(text)
    if not f then return false end
    peer.cursor = math.max(peer.cursor or 0, f.d)
    if seal ~= Stats.Seal(wire, Short(sender)) or not Stats.Plausible(f, self.now()) then
        peer.refused = (peer.refused or 0) + 1
        return false
    end
    local held = peer.q[f.q]
    if type(held) == "string" then
        if held ~= text then peer.flag = true end
        return false
    end
    peer.q[f.q] = text
    self.shared = nil
    gossip[sender] = true
    return true
end

--- Our records handed in after `since`, oldest first, a page of them to `sender`.
function Stats:SendPage(since, sender)
    if #queue > QUEUE_MAX then return end
    local list = {}
    for questID, rec in pairs(self:Quests()) do
        if rec.v == 2 and rec.d and not rec.bad and rec.d > since then list[#list + 1] = { id = questID, rec = rec } end
    end
    table.sort(list, function(a, b)
        if a.rec.d ~= b.rec.d then return a.rec.d < b.rec.d end
        return a.id < b.id
    end)
    -- A page never ends between two records of the same moment: the next starts after it.
    local last = math.min(PAGE, #list)
    while last < #list and list[last + 1].rec.d == list[last].rec.d do
        last = last + 1
    end
    local line = "F|"
    for i = 1, last do
        local one = Sealed(list[i].id, list[i].rec)
        if #line > 2 and #line + #one + 1 > 250 then
            self:Send(line, sender)
            line = "F|"
        end
        line = line .. (#line > 2 and ";" or "") .. one
    end
    if #line > 2 then self:Send(line, sender) end
    self:Send(string.format("E|%d|%d", last < #list and 1 or 0, last > 0 and list[last].rec.d or since), sender)
end

--- A message from `sender` (full name), when they are a friend, in the party or in the guild
--- (`channel`: how it came).
function Stats:Receive(text, sender, friends, channel)
    friends = friends or self.Friends()
    if type(text) ~= "string" or not sender or sender == Me() then return end
    local broadcast = channel == "GUILD" or channel == "PARTY"
    if broadcast and Short(sender) == MyName() then return end -- our own, back from the channel
    if not (channel == "GUILD" or friends.allowed[sender]) then return end
    local kind, a, b, c, d, e, f, g, h, i = strsplit("|", text)
    local peers = DB().peers
    local peer = peers[sender] or { q = {} }
    peers[sender] = peer
    peer.at = self.now()
    if kind == "H" then
        peer.total, peer.count = tonumber(b) or 0, tonumber(c) or 0
        if (tonumber(a) or 1) >= 2 then
            peer.v = 2
            if h and h:match("^%u+$") then peer.class = h end
            if tonumber(i) and tonumber(i) > 0 then peer.level = math.min(100, math.floor(tonumber(i))) end
            -- What they scored before these rules: as they first said it.
            if not peer.lt then peer.lt, peer.lc = tonumber(f) or 0, tonumber(g) or 0 end
            local mark, records = tonumber(d) or 0, tonumber(e) or 0
            local have, mine = Held(peer)
            if records == have and mark ~= mine then
                peer.flag = true -- as many records as we hold, and not the same ones
            elseif records > have and asked[sender] ~= records .. ":" .. mark then
                asked[sender] = records .. ":" .. mark
                self:Send("S|" .. (peer.cursor or 0), sender)
            end
        else
            local have = 0
            for _ in pairs(peer.q) do
                have = have + 1
            end
            if peer.count > have then self:Send("R|" .. (peer.last or 0), sender) end
        end
        if not broadcast and (helloAt[sender] or 0) + HELLO_AGAIN < self.now() then
            helloAt[sender] = self.now()
            self:Hello(sender)
        end
    elseif kind == "R" then
        local since = tonumber(a) or 0
        local list = {}
        for id, rec in pairs(self:Quests()) do
            local at = rec.v == 2 and rec.d or (not rec.v and not rec.p and rec.e) or nil
            if at and not rec.bad and at > since then list[#list + 1] = { id = id, rec = rec, at = at } end
        end
        table.sort(list, function(x, y) return x.at > y.at end)
        for i = 1, math.min(MAX_SENT, #list) do
            self:Send(self.Record(list[i].id, list[i].rec), sender)
        end
    elseif kind == "Q" then
        local questID = tonumber(a)
        if not questID or peer.v == 2 then return end
        local finishedAt = tonumber(e) or 0
        peer.q[questID] = { t = tonumber(b), r = tonumber(c), s = tonumber(d) or 0, e = finishedAt }
        peer.last = math.max(peer.last or 0, finishedAt)
    elseif kind == "S" then
        self:SendPage(tonumber(a) or 0, sender)
    elseif kind == "F" then
        peer.v = 2
        for one in text:sub(3):gmatch("[^;]+") do
            self:Take(sender, peer, one)
        end
    elseif kind == "E" then
        peer.cursor = math.max(peer.cursor or 0, tonumber(b) or 0)
        if a == "1" then
            self:Send("S|" .. peer.cursor, sender)
        elseif not peer.full and Held(peer) < (tonumber((asked[sender] or ""):match("^(%d+)")) or 0) then
            -- Records still missing after the last page (handed in on another computer, before
            -- those we hold): once, everything again.
            peer.full = true
            self:Send("S|0", sender)
        end
    elseif kind == "P" then
        -- What a friend holds of a player: as many records as we hold, and not the same ones?
        local other = a and peers[a]
        if other and a ~= sender and other.v == 2 then
            local have, mine = Held(other)
            if have > 0 and have == tonumber(b) and mine ~= tonumber(c) then other.flag = true end
        end
        if not next(peer.q) and not peer.total then peers[sender] = nil end
    end
    self:RefreshBoard()
end

--- Hello to the friends online now (those we did not greet lately) and to the guild; and to
--- each friend, what we now hold of the others: two friends of one player compare it.
function Stats:HelloAll()
    if not FG:Get("statsShare") then return end
    local friends = self.Friends()
    local now = self.now()
    local direct = {}
    for _, name in ipairs(friends.whispers) do
        direct[#direct + 1] = name
    end
    for _, name in pairs(friends.bnet) do
        direct[#direct + 1] = name
    end
    for _, name in ipairs(direct) do
        if (helloAt[name] or 0) + HELLO_AGAIN < now then
            helloAt[name] = now
            self:Hello(name)
        end
    end
    if IsInGuild and IsInGuild() and (helloAt.GUILD or 0) + HELLO_AGAIN < now then
        helloAt.GUILD = now
        self:Hello(nil, "GUILD")
    end
    local peers = DB().peers
    for about in pairs(gossip) do
        local peer = peers[about]
        if peer and not guild[about] then
            local have, mark = Held(peer)
            for _, name in ipairs(direct) do
                if name ~= about then self:Send(string.format("P|%s|%d|%d", about, have, mark), name) end
            end
        end
        gossip[about] = nil
    end
end

-- The leaderboard ------------------------------------------------------------------------------
--
-- A list of the players (rank, class, name, total, quests, average, and a bar of what their
-- average quest is made of) under two tabs, Friends and Guild, and to its right the detail of
-- one of them: the parts of their average quest, the colors of their quests and their latest
-- quests (time, luck, points). It opens on you; a click on a player shows theirs. The corner at
-- the bottom right drags the window taller or shorter (more or fewer players) and wider; the
-- line between the list and the detail drags one wider and the other narrower. Mouse wheel:
-- the list, or the quests.

local LIST_W, PANE_W = 480, 330
--- How narrow and how wide the list and the detail may be dragged.
local LIST_MIN, LIST_MAX, PANE_MIN, PANE_MAX = 400, 760, 270, 640
local TITLE_H, TABS_H, HEAD_H, ROW_H, LEGEND_H, NOTE_H, QUEST_H = 28, 23, 20, 24, 22, 20, 18
local MIN_ROWS, MAX_ROWS, DEFAULT_ROWS = 4, 30, 19
--- What the detail holds above its quests, and under them.
local PANE_TOP, PANE_BOTTOM = 148, 8
--- The bar of an average quest: where it starts in a row, its width in a list of LIST_W, and
--- the points it holds when full.
local BAR_LEFT, BAR_W, BAR_POINTS = 308, 140, 186
--- Two-color fades (the window, the title, the rows, the bars) where the client draws them;
--- false: flat colors only.
local GRADIENTS = true
--- The game's colors of a quest for a character's level: red, orange, yellow, green, gray.
local DIFFICULTY = { { 1, 0.1, 0.1 }, { 1, 0.5, 0.25 }, { 1, 1, 0 }, { 0.25, 0.75, 0.25 }, { 0.5, 0.5, 0.5 } }
--- The parts of a score on the bars: the color at the top and at the bottom of each. `old`: what
--- was scored before these rules, of which no part is known.
local PARTS = {
    { key = "old", top = { 0.55, 0.6, 0.7 }, bottom = { 0.3, 0.34, 0.42 } },
    { key = "base", top = { 0.42, 0.48, 1 }, bottom = { 0.15, 0.2, 0.72 } },
    { key = "speed", top = { 0.32, 0.82, 0.96 }, bottom = { 0.07, 0.48, 0.62 } },
    { key = "luck", top = { 0.53, 0.95, 0.67 }, bottom = { 0.16, 0.6, 0.33 } },
    { key = "lost", top = { 1, 0.58, 0.5 }, bottom = { 0.72, 0.2, 0.12 } },
}

local B = {
    friends = T("Friends"),
    guild = T("Guild"),
    player = T("Player"),
    total = T("Total"),
    quests = T("Quests"),
    avg = T("Avg"),
    byPart = T("Average quest, by part"),
    base = T("Base"),
    speed = T("Speed"),
    luck = T("Luck"),
    deaths = T("Deaths"),
    lost = T("Lost to deaths or bad luck"),
    old = T("Old rules"),
    refused = T("%s: records refused, not counted"),
    difficulty = T("Quest difficulty"),
    recent = T("Recent quests"),
    time = T("Time"),
    points = T("Pts"),
    escort = T("escort"),
    bought = T("%d of %d bought"),
    level = T("Level %d"),
    summary = T("%d quests  avg %d per quest"),
    range = T("%d-%d of %d"),
    before = T("before these rules"),
}

local function Thousands(n)
    local s = tostring(math.floor(n + 0.5))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

--- A two-color fade on a texture, top to bottom; flat (their mean) where the client has none.
local function Fade(texture, top, bottom, a1, a2)
    a1, a2 = a1 or 1, a2 or a1 or 1
    local ok = GRADIENTS
        and CreateColor
        and texture.SetGradient
        and pcall(function()
            texture:SetColorTexture(1, 1, 1, 1)
            texture:SetGradient(
                "VERTICAL",
                CreateColor(bottom[1], bottom[2], bottom[3], a2),
                CreateColor(top[1], top[2], top[3], a1)
            )
        end)
    if not ok then
        local r, g, b = (top[1] + bottom[1]) / 2, (top[2] + bottom[2]) / 2, (top[3] + bottom[3]) / 2
        texture:SetColorTexture(r, g, b, (a1 + a2) / 2)
    end
end

--- A wash of a skin color fading to the right (flat and lighter without gradients).
local function Wash(texture, color, a1, a2)
    if GRADIENTS then return FG.Skin:Gradient(texture, color, a1, a2) end
    local c = FG.Skin.colors[color]
    texture:SetColorTexture(c[1], c[2], c[3], (a1 + a2) / 3)
end

--- A player's class color (the game's), gray when the class is not known.
local function ClassColor(class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if type(c) == "table" and type(c.r) == "number" then return c.r, c.g, c.b end
    return 0.3, 0.33, 0.4
end

local function MyClass()
    local _, class = UnitClass("player")
    class = Readable(class)
    return type(class) == "string" and class or nil
end
Stats.MyClass = MyClass

--- What a set of records makes of a player: adds the record `f` of `questID` to the entry.
local out = {}
local function AddRecord(self, entry, f, questID, held)
    local score = self:Score(f, questID, held, out)
    entry.total, entry.count, entry.records = entry.total + score, entry.count + 1, entry.records + 1
    local parts = entry.parts
    parts.base, parts.speed = parts.base + out.base, parts.speed + out.speed
    parts.luck, parts.lost = parts.luck + math.max(0, out.luck), parts.lost + out.lost + math.max(0, -out.luck)
    parts.deaths = parts.deaths + out.lost
    parts.net = parts.net + out.luck
    local color = Stats.Color(f.lv, f.pl)
    entry.colors[color] = entry.colors[color] + 1
end

local function Entry(name, full)
    return {
        name = name,
        full = full,
        total = 0,
        count = 0,
        records = 0,
        parts = { old = 0, base = 0, speed = 0, luck = 0, lost = 0, deaths = 0, net = 0 },
        colors = { 0, 0, 0, 0, 0 },
    }
end

--- The board's lines: me and every friend seen, by total score. Each: name, full (name and
--- realm), total, count (quests), records (those under these rules), parts (their sums over
--- these: base, speed, luck, lost, deaths, net), colors (quests of each), class, level, flag,
--- refused; me.
function Stats:Standings()
    local me = Entry(UnitName("player"), "")
    me.me, me.class, me.level = true, MyClass(), tonumber(Readable(UnitLevel("player")))
    for questID, rec in pairs(self:Quests()) do
        if rec.v == 2 then
            if rec.d and not rec.bad then AddRecord(self, me, rec, questID, true) end
        elseif rec.e and not rec.p then
            me.total, me.count = me.total + (rec.sc or 0), me.count + 1
        end
    end
    me.parts.old = me.total - me.parts.base - me.parts.speed - me.parts.net + me.parts.deaths
    me.parts.old = math.max(0, me.parts.old)
    local circle = self.Friends()
    local list = { me }
    for full, peer in pairs(DB().peers) do
        -- Someone who only asked for records so far has nothing to show.
        if peer.total or next(peer.q) then
            local e = Entry((full:gsub("%-.*", "")), full)
            local known = circle.class[full]
            e.class, e.level = peer.class or known and known.class, peer.level or known and known.level
            e.flag, e.refused, e.peer = peer.flag, peer.refused, peer
            if peer.v == 2 then
                e.total, e.count = peer.lt or 0, peer.lc or 0
                e.parts.old = e.total
                for questID, text in pairs(peer.q) do
                    local f = type(text) == "string" and Facts(text)
                    if f then AddRecord(self, e, f, questID, not peer.flag) end
                end
            else
                e.total, e.count = peer.total or 0, peer.count or 0
                e.parts.old = e.total
            end
            list[#list + 1] = e
        end
    end
    table.sort(list, function(a, b)
        if a.total ~= b.total then return a.total > b.total end
        return a.name < b.name
    end)
    return list
end

--- A friend's total and quests (Stats:Standings works them out for the board).
function Stats:PeerTotal(peer)
    for _, e in ipairs(self:Standings()) do
        if e.peer == peer then return e.total, e.count end
    end
    return 0, 0
end

--- A player's quests, latest first: { q, d (when), pts, t (seconds), luck (points, nil: none),
--- color, escort, bought, of (units bought of the items asked), old (before these rules) }.
function Stats:History(entry)
    local list = {}
    local function Add(questID, f, held)
        local pts = self:Score(f, questID, held, out)
        local s = self:Shared()[questID]
        local bought = (f.ob or 0) + (s and s.farm and (f.ou or 0) or 0)
        list[#list + 1] = {
            q = questID,
            d = f.d,
            pts = pts,
            t = (f.x or 0) == 0 and f.t or nil,
            luck = out.rated and math.floor(out.luck + (out.luck >= 0 and 0.5 or -0.5)) or nil,
            color = Stats.Color(f.lv, f.pl),
            escort = (f.x or 0) ~= 0,
            bought = bought > 0 and bought or nil,
            of = f.it,
        }
    end
    if entry.me then
        for questID, rec in pairs(self:Quests()) do
            if rec.v == 2 then
                if rec.d and not rec.bad then Add(questID, rec, true) end
            elseif rec.e and not rec.p then
                list[#list + 1] = { q = questID, d = rec.e, pts = rec.sc or 0, t = rec.t, old = true, color = 3 }
            end
        end
    elseif entry.peer then
        for questID, text in pairs(entry.peer.q) do
            if type(text) == "table" then
                list[#list + 1] = { q = questID, d = text.e or 0, pts = text.s or 0, t = text.t, old = true, color = 3 }
            else
                local f = Facts(text)
                if f then Add(questID, f, not entry.peer.flag) end
            end
        end
    end
    table.sort(list, function(a, b)
        if a.d ~= b.d then return a.d > b.d end
        return a.q < b.q
    end)
    return list
end

local function QuestName(questID)
    local name = QuestLog.GetTitleForQuestID and Readable(QuestLog.GetTitleForQuestID(questID))
    return type(name) == "string" and name ~= "" and name or ("#" .. questID)
end

-- Its frames ------------------------------------------------------------------------------------

local function Text(parent, size, color, width, justify)
    local fs = FG.Skin:Text(parent, size, color)
    if width then fs:SetWidth(width) end
    if justify then fs:SetJustifyH(justify) end
    return fs
end

local function Solid(parent, layer, r, g, b, a)
    local t = parent:CreateTexture(nil, layer or "ARTWORK")
    t:SetColorTexture(r, g, b, a or 1)
    return t
end

local function Clamp(value, low, high) return math.max(low, math.min(high, value)) end

--- The window's sizes, as the player left them: rows of players, the list's width, the detail's.
local function Rows() return Clamp(math.floor(tonumber(DB().boardRows) or DEFAULT_ROWS), MIN_ROWS, MAX_ROWS) end
local function ListWidth() return Clamp(math.floor(tonumber(DB().boardList) or LIST_W), LIST_MIN, LIST_MAX) end
local function PaneWidth() return Clamp(math.floor(tonumber(DB().boardPane) or PANE_W), PANE_MIN, PANE_MAX) end

local function BodyHeight(rows) return TABS_H + HEAD_H + rows * ROW_H + LEGEND_H + NOTE_H end

--- A bar of a score's parts: a dark track and one piece for each part, `width` wide.
local function Bar(parent, width)
    local bar = CreateFrame("Frame", nil, parent)
    bar.width = width
    bar:SetSize(width, 10)
    bar.track = Solid(bar, "BACKGROUND", 0.016, 0.035, 0.071, 1)
    bar.track:SetAllPoints()
    bar.pieces = {}
    for i, part in ipairs(PARTS) do
        local piece = bar:CreateTexture(nil, "ARTWORK")
        Fade(piece, part.top, part.bottom)
        piece:SetHeight(8)
        bar.pieces[i] = piece
    end
    return bar
end

--- Fill a bar with a player's average quest (`parts`: sums over their `n` quests).
local function SetBar(bar, parts, n)
    local x, room = 1, bar.width - 2
    for i, part in ipairs(PARTS) do
        local piece = bar.pieces[i]
        local points = n > 0 and parts[part.key] / n or 0
        local width = math.floor(points * bar.width / BAR_POINTS + 0.5)
        if part.key == "lost" and points > 0.5 then width = math.max(2, width) end
        width = math.min(room, width)
        piece:ClearAllPoints()
        if width >= 1 then
            piece:SetPoint("LEFT", bar, "LEFT", x, 0)
            piece:SetWidth(width)
            piece:Show()
            x, room = x + width, room - width
        else
            piece:Hide()
        end
    end
end

--- A thin scroll mark: where `first` to `first + shown - 1` are among `total` lines.
local function SetScroll(mark, first, shown, total, height)
    if total <= shown then return mark:Hide() end
    local thumb = math.max(12, math.floor(height * shown / total))
    mark:ClearAllPoints()
    mark:SetPoint("TOPRIGHT", mark.host, "TOPRIGHT", 0, -math.floor((height - thumb) * (first - 1) / (total - shown)))
    mark:SetHeight(thumb)
    mark:Show()
end

local function BoardRow(i)
    local board = Stats.board
    local r = board.rows[i]
    if r then return r end
    r = CreateFrame("Button", nil, board.list)
    r:SetSize(LIST_W - 12, ROW_H)
    r:SetPoint("TOPLEFT", 1, -(i - 1) * ROW_H)
    r.wash = r:CreateTexture(nil, "BACKGROUND")
    r.wash:SetAllPoints()
    r.rank = Text(r, 11, "muted", 22)
    r.rank:SetPoint("LEFT", 9, 0)
    r.flag = Text(r, 12, "red", 10, "CENTER")
    r.flag:SetPoint("LEFT", 31, 0)
    r.flag:SetText("!")
    r.class = Solid(r, "ARTWORK", 0.3, 0.33, 0.4, 1)
    r.class:SetSize(12, 12)
    r.class:SetPoint("LEFT", 42, 0)
    r.name = Text(r, 12, "text", 88)
    r.name:SetPoint("LEFT", 62, 0)
    r.total = Text(r, 12, "gold", 62, "RIGHT")
    r.total:SetPoint("LEFT", 150, 0)
    r.quests = Text(r, 11, "text2", 46, "RIGHT")
    r.quests:SetPoint("LEFT", 212, 0)
    r.avg = Text(r, 11, "text2", 36, "RIGHT")
    r.avg:SetPoint("LEFT", 258, 0)
    r.bar = Bar(r, BAR_W)
    r.bar:SetPoint("LEFT", BAR_LEFT, 0)
    r:SetScript("OnClick", function(self)
        Stats.selected, Stats.questOffset = self.full, 0
        Stats:FillBoard()
    end)
    FG:DragHandle(r)
    board.rows[i] = r
    return r
end

local function QuestRow(i)
    local pane = Stats.board.pane
    local r = pane.rows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, pane.quests)
    r:SetSize(PANE_W - 26, QUEST_H)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * QUEST_H)
    r.color = Solid(r, "ARTWORK", 1, 1, 0, 1)
    r.color:SetSize(8, 8)
    r.color:SetPoint("LEFT", 0, 0)
    r.name = Text(r, 11, "text", 160)
    r.name:SetPoint("LEFT", 14, 0)
    r.time = Text(r, 11, "text2", 40, "RIGHT")
    r.time:SetPoint("RIGHT", -72, 0)
    r.luck = Text(r, 11, "text2", 36, "RIGHT")
    r.luck:SetPoint("RIGHT", -36, 0)
    r.pts = Text(r, 11, "gold", 36, "RIGHT")
    r.pts:SetPoint("RIGHT", 0, 0)
    pane.rows[i] = r
    return r
end

--- The players of the tab shown, of those the board lists.
local function InScope(list, scope, circle)
    local shown, friends, guildCount = {}, 0, 0
    for _, e in ipairs(list) do
        local inGuild = e.me and next(circle.guild) ~= nil or (not e.me and circle.guild[e.full]) or false
        local friend = e.me or circle.friends[e.full] or not inGuild
        if friend then friends = friends + 1 end
        if inGuild then guildCount = guildCount + 1 end
        if (scope == "guild" and inGuild) or (scope ~= "guild" and friend) then shown[#shown + 1] = e end
    end
    return shown, friends, guildCount
end

--- Put every piece of the window where its sizes say: `rows` of players, the list `listW` wide,
--- the detail `paneW` wide.
local function Layout(board, rows, listW, paneW)
    local body = BodyHeight(rows)
    board:SetSize(listW + paneW + 2, TITLE_H + body + 2)
    board.range:ClearAllPoints()
    board.range:SetPoint("TOPRIGHT", board, "TOPLEFT", listW - 8, -TITLE_H - 6)
    board.under:SetWidth(listW)
    board.list:SetSize(listW, rows * ROW_H)
    board.legend:SetWidth(listW)
    board.over:SetWidth(listW)
    board.note:SetWidth(listW - 50)
    board.barWidth = math.max(40, listW - BAR_LEFT - 32)
    local pane = board.pane
    pane:ClearAllPoints()
    pane:SetPoint("TOPLEFT", board, "TOPLEFT", listW + 1, -TITLE_H)
    pane:SetSize(paneW, body)
    board.divider:ClearAllPoints()
    board.divider:SetPoint("TOPLEFT", board, "TOPLEFT", listW - 2, -TITLE_H)
    board.divider:SetSize(7, body)
    local tileWidth = (paneW - 18 - 18) / 4
    for i, tile in ipairs(pane.tiles) do
        tile:ClearAllPoints()
        tile:SetPoint("TOPLEFT", 10 + (i - 1) * (tileWidth + 6), -58)
        tile:SetSize(tileWidth, 38)
    end
    pane.bar.width = Clamp(paneW - 200, 50, BAR_W)
    pane.bar:SetWidth(pane.bar.width)
    pane.strip.width = math.max(40, paneW - 8 - pane.strip.left)
    pane.strip:SetWidth(pane.strip.width)
    return body
end

--- Fill the detail with a player (nothing without one).
local function FillPane(board, entry, questRows, paneW)
    local pane = board.pane
    pane.content:SetShown(entry ~= nil)
    if not entry then return end
    local n = entry.records
    pane.class:SetColorTexture(ClassColor(entry.class))
    pane.name:SetText(entry.name)
    local who = entry.level and string.format(B.level, entry.level) or ""
    local class = entry.class and LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[entry.class]
    if type(class) == "string" then who = who .. (who ~= "" and " " or "") .. class end
    pane.who:SetText(who)
    pane.total:SetText(string.format(L.pts, entry.total))
    local avg = entry.count > 0 and math.floor(entry.total / entry.count + 0.5) or 0
    pane.summary:SetText(string.format(B.summary, entry.count, avg))
    SetBar(pane.bar, entry.parts, entry.count)
    local function Mean(key, sign)
        if n == 0 then return "-" end
        local v = math.floor(entry.parts[key] / n + 0.5)
        if sign and v > 0 then return "+" .. v end
        return tostring(sign == false and v > 0 and -v or v)
    end
    pane.tiles[1].value:SetText(Mean("base"))
    pane.tiles[2].value:SetText(Mean("speed"))
    pane.tiles[3].value:SetText(Mean("net", true))
    pane.tiles[4].value:SetText(Mean("deaths", false))
    local net = n > 0 and entry.parts.net or 0
    local c = FG.Skin.colors[net > 0 and "green" or net < 0 and "red" or "text"]
    pane.tiles[3].value:SetTextColor(c[1], c[2], c[3])
    -- The colors of their quests: one piece each, by share.
    local x, width = 0, pane.strip.width
    for i, piece in ipairs(pane.strip.pieces) do
        local w = n > 0 and math.floor(width * entry.colors[i] / n + 0.5) or 0
        piece:ClearAllPoints()
        if w >= 1 and x < width then
            piece:SetPoint("LEFT", pane.strip, "LEFT", x, 0)
            piece:SetWidth(math.min(w, width - x))
            piece:Show()
            x = x + w
        else
            piece:Hide()
        end
    end
    local history = Stats:History(entry)
    local last = math.max(0, #history - questRows)
    Stats.questOffset = Clamp(Stats.questOffset or 0, 0, last)
    for i = 1, questRows do
        local r = QuestRow(i)
        local h = history[i + Stats.questOffset]
        r:SetShown(h ~= nil)
        if h then
            r:SetWidth(paneW - 26)
            r.name:SetWidth(math.max(40, paneW - 26 - 14 - 122))
            local color = DIFFICULTY[h.color]
            r.color:SetColorTexture(color[1], color[2], color[3], 1)
            local tag = h.old and B.before
                or h.escort and B.escort
                or h.bought and string.format(B.bought, h.bought, h.of or h.bought)
                or nil
            r.name:SetText(QuestName(h.q) .. (tag and ("  |cff7e8ba3" .. tag .. "|r") or ""))
            r.time:SetText(h.t and Clock(h.t) or "-")
            r.luck:SetText(h.luck and (h.luck > 0 and "+" .. h.luck or tostring(h.luck)) or "-")
            local lc = FG.Skin.colors[h.luck and h.luck > 0 and "green" or h.luck and h.luck < 0 and "red" or "muted"]
            r.luck:SetTextColor(lc[1], lc[2], lc[3])
            r.pts:SetText(tostring(h.pts))
        end
    end
    for i = questRows + 1, #pane.rows do
        pane.rows[i]:Hide()
    end
    SetScroll(pane.mark, Stats.questOffset + 1, questRows, #history, questRows * QUEST_H)
end

function Stats:FillBoard()
    local board = self.board
    if not board then return end
    local rows, listW, paneW = Rows(), ListWidth(), PaneWidth()
    local body = Layout(board, rows, listW, paneW)
    local circle = self.Friends()
    local scope = self.scope == "guild" and "guild" or "friends"
    local shown, friends, guildCount = InScope(self:Standings(), scope, circle)
    -- The detail always shows a player: the one clicked, else you, else the first of the tab.
    local selected, mine
    for _, e in ipairs(shown) do
        if self.selected and (e.me and "me" or e.full) == self.selected then selected = e end
        if e.me then mine = e end
    end
    selected = selected or mine or shown[1]
    self.selected = selected and (selected.me and "me" or selected.full) or nil
    for key, tab in pairs(board.tabs) do
        local on = key == scope
        local c = FG.Skin.colors[on and "text" or "muted"]
        tab.label:SetTextColor(c[1], c[2], c[3])
        local name, players = B.friends, friends
        if key == "guild" then
            name, players = B.guild, guildCount
        end
        tab.label:SetText(name .. "  " .. players)
        tab:SetWidth((tab.label:GetStringWidth() or 40) + 16)
        tab.line:SetShown(on)
    end
    local last = math.max(0, #shown - rows)
    self.offset = Clamp(self.offset or 0, 0, last)
    board.range:SetText(#shown > rows and string.format(B.range, self.offset + 1, self.offset + rows, #shown) or "")
    for i = 1, rows do
        local r = BoardRow(i)
        local e = shown[i + self.offset]
        r:SetShown(e ~= nil)
        if e then
            r:SetWidth(listW - 12)
            r.bar.width = board.barWidth
            r.bar:SetWidth(board.barWidth)
            r.full = e.me and "me" or e.full
            r.rank:SetText((i + self.offset) .. ".")
            r.flag:SetShown((e.flag or (e.refused or 0) > 0) and true or false)
            r.class:SetColorTexture(ClassColor(e.class))
            r.name:SetText(e.me and (e.name .. " (" .. L.you .. ")") or e.name)
            local c = FG.Skin.colors[e.me and "green" or e.flag and "red" or "text"]
            r.name:SetTextColor(c[1], c[2], c[3])
            r.total:SetText(Thousands(e.total))
            r.quests:SetText(tostring(e.count))
            r.avg:SetText(e.count > 0 and tostring(math.floor(e.total / e.count + 0.5)) or "-")
            SetBar(r.bar, e.parts, e.count)
            if e == selected then
                Wash(r.wash, "accent", 0.5, 0.06)
                r.wash:Show()
            elseif e.me then
                Wash(r.wash, "green", 0.26, 0)
                r.wash:Show()
            else
                r.wash:Hide()
            end
        end
    end
    for i = rows + 1, #board.rows do
        board.rows[i]:Hide()
    end
    local noted
    for _, e in ipairs(shown) do
        if not noted and (e.flag or (e.refused or 0) > 0) then noted = e end
    end
    board.noteMark:SetShown(noted ~= nil)
    local alone = #shown == 1 and scope ~= "guild"
    board.note:SetText(noted and string.format(B.refused, noted.name) or alone and L.none or "")
    SetScroll(board.mark, self.offset + 1, rows, #shown, rows * ROW_H)
    FillPane(board, selected, math.max(1, math.floor((body - PANE_TOP - PANE_BOTTOM) / QUEST_H)), paneW)
end

local refreshing = false

--- Fill the board again, when it shows: once a second at most (records come by the page).
function Stats:RefreshBoard()
    if not (self.board and self.board:IsShown()) or refreshing then return end
    if not (C_Timer and C_Timer.After) then return self:FillBoard() end
    refreshing = true
    C_Timer.After(1, function()
        refreshing = false
        if Stats.board and Stats.board:IsShown() then Stats:FillBoard() end
    end)
end

--- The window's own close button, in its colors: a small dark square with an x, red under the
--- mouse (the game's red and gold one does not go with the panel).
local function CloseButton(board)
    local b = CreateFrame("Button", nil, board)
    b:SetSize(16, 16)
    b:SetPoint("TOPRIGHT", -6, -6)
    b:SetFrameLevel((board:GetFrameLevel() or 1) + 10)
    local edge, bg, red = FG.Skin.colors.edge, FG.Skin.colors.bg, FG.Skin.colors.red
    b.edge = Solid(b, "BACKGROUND", edge[1], edge[2], edge[3], 1)
    b.edge:SetAllPoints()
    b.fill = Solid(b, "BORDER", bg[1], bg[2], bg[3], 1)
    b.fill:SetPoint("TOPLEFT", 1, -1)
    b.fill:SetPoint("BOTTOMRIGHT", -1, 1)
    b.x = Text(b, 12, "text2", nil, "CENTER")
    b.x:SetPoint("CENTER", 0, 1)
    b.x:SetText("x")
    b:SetScript("OnEnter", function()
        b.fill:SetColorTexture(red[1] * 0.7, red[2] * 0.7, red[3] * 0.7, 1)
        b.x:SetTextColor(1, 1, 1)
    end)
    b:SetScript("OnLeave", function()
        b.fill:SetColorTexture(bg[1], bg[2], bg[3], 1)
        local c = FG.Skin.colors.text2
        b.x:SetTextColor(c[1], c[2], c[3])
    end)
    b:SetScript("OnClick", function() board:Hide() end)
    return b
end

--- Make `handle` a thing dragged with the mouse held: `moved(dx, dy)` is called as it goes, with
--- how far the mouse is from where it was pressed (right and down are positive), in the
--- window's own units. The window is held by its top left corner meanwhile: it grows from there.
local function Dragged(handle, board, pressed, moved)
    local startX, startY, scale
    local function Stop()
        handle:SetScript("OnUpdate", nil)
        startX = nil
    end
    handle:SetScript("OnMouseDown", function()
        scale = board:GetEffectiveScale()
        local x, y = GetCursorPosition()
        local left, top = board:GetLeft(), board:GetTop()
        for _, v in ipairs({ x or false, y or false, scale or false, left or false, top or false }) do
            if type(v) ~= "number" then return end
        end
        board:ClearAllPoints()
        board:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
        startX, startY = x / scale, y / scale
        pressed()
        handle:SetScript("OnUpdate", function()
            local nowX, nowY = GetCursorPosition()
            if not startX or type(nowX) ~= "number" or type(nowY) ~= "number" then return Stop() end
            moved(nowX / scale - startX, startY - nowY / scale)
        end)
    end)
    handle:SetScript("OnMouseUp", Stop)
    handle:SetScript("OnHide", Stop)
end

--- The corner at the bottom right: dragged down or up, the window shows more or fewer players
--- (whole rows); dragged right or left, its detail is wider or narrower.
local function Grip(board)
    local grip = CreateFrame("Button", nil, board)
    grip:SetSize(14, 14)
    grip:SetPoint("BOTTOMRIGHT", -1, 1)
    grip:SetFrameLevel((board:GetFrameLevel() or 1) + 10)
    local art = grip:CreateTexture(nil, "OVERLAY")
    art:SetAllPoints()
    art:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    local accent = FG.Skin.colors.accent
    art:SetVertexColor(accent[1], accent[2], accent[3], 0.9)
    grip.art = art
    local rows, pane
    Dragged(grip, board, function()
        rows, pane = Rows(), PaneWidth()
    end, function(dx, dy)
        local db = DB()
        local newRows = Clamp(rows + math.floor(dy / ROW_H + 0.5), MIN_ROWS, MAX_ROWS)
        local newPane = Clamp(math.floor(pane + dx + 0.5), PANE_MIN, PANE_MAX)
        if newRows ~= Rows() or newPane ~= PaneWidth() then
            db.boardRows, db.boardPane = newRows, newPane
            Stats:FillBoard()
        end
    end)
    return grip
end

--- The line between the list and the detail: dragged, one gets what the other gives up.
local function Divider(board)
    local divider = CreateFrame("Button", nil, board)
    divider:SetFrameLevel((board:GetFrameLevel() or 1) + 8)
    local edge, accent = FG.Skin.colors.edge, FG.Skin.colors.accent
    divider.line = Solid(divider, "ARTWORK", edge[1], edge[2], edge[3], 1)
    divider.line:SetPoint("TOP", 0, 0)
    divider.line:SetPoint("BOTTOM", 0, 0)
    divider.line:SetWidth(1)
    local function Lit(on)
        if on then
            divider.line:SetColorTexture(accent[1], accent[2], accent[3], 1)
            divider.line:SetWidth(3)
        else
            divider.line:SetColorTexture(edge[1], edge[2], edge[3], 1)
            divider.line:SetWidth(1)
        end
    end
    local held = false
    divider:SetScript("OnEnter", function() Lit(true) end)
    divider:SetScript("OnLeave", function()
        if not held then Lit(false) end
    end)
    local list, pane
    Dragged(divider, board, function()
        list, pane, held = ListWidth(), PaneWidth(), true
        Lit(true)
    end, function(dx)
        -- What the list takes, the detail gives: the window keeps its width.
        dx = Clamp(dx, math.max(LIST_MIN - list, pane - PANE_MAX), math.min(LIST_MAX - list, pane - PANE_MIN))
        local newList = math.floor(list + dx + 0.5)
        if newList ~= ListWidth() then
            local db = DB()
            db.boardList, db.boardPane = newList, list + pane - newList
            Stats:FillBoard()
        end
    end)
    divider:HookScript("OnMouseUp", function()
        held = false
        Lit(false)
    end)
    return divider
end

local function BuildBoard()
    local board = CreateFrame("Frame", "PathwrightLeaderboard", FG.UIRoot, "BackdropTemplate")
    board:SetPoint("CENTER")
    board:SetFrameStrata("DIALOG")
    board:SetClampedToScreen(true)
    FG:Draggable(board)
    board.rows, board.tabs = {}, {}
    -- The window fades from near black down to indigo; its title carries a wash of the accent.
    if GRADIENTS then
        board.fade = board:CreateTexture(nil, "BACKGROUND", nil, 1)
        board.fade:SetPoint("TOPLEFT", 1, -1)
        board.fade:SetPoint("BOTTOMRIGHT", -1, 1)
        Fade(board.fade, { 0.02, 0.035, 0.07 }, { 0.11, 0.157, 0.29 }, 0.94, 0.94)
        board.wash = board:CreateTexture(nil, "BACKGROUND", nil, 2)
        board.wash:SetPoint("TOPLEFT", 1, -1)
        board.wash:SetPoint("TOPRIGHT", -1, -1)
        board.wash:SetHeight(TITLE_H - 1)
        Wash(board.wash, "accent", 0.42, 0)
    end
    board.title = Text(board, 13, "text")
    board.title:SetPoint("TOPLEFT", 10, -8)
    board.title:SetText(L.board)
    board.close = CloseButton(board)
    local line = FG.Skin.colors.line

    -- The tabs, and which players of how many show.
    for _, key in ipairs({ "friends", "guild" }) do
        local tab = CreateFrame("Button", nil, board)
        tab:SetSize(70, TABS_H - 1)
        tab.label = Text(tab, 11, "text")
        tab.label:SetPoint("LEFT", 8, 0)
        tab.line = FG.Skin:Fill(tab, "ARTWORK", "accent", 1)
        tab.line:SetPoint("BOTTOMLEFT", 0, 0)
        tab.line:SetPoint("BOTTOMRIGHT", 0, 0)
        tab.line:SetHeight(2)
        tab:SetScript("OnClick", function()
            Stats.scope, Stats.offset, Stats.selected, Stats.questOffset = key, 0, nil, 0
            Stats:FillBoard()
        end)
        board.tabs[key] = tab
    end
    board.tabs.friends:SetPoint("TOPLEFT", 3, -TITLE_H)
    board.tabs.guild:SetPoint("TOPLEFT", board.tabs.friends, "TOPRIGHT", 4, 0)
    board.range = Text(board, 10, "muted", 90, "RIGHT")
    board.under = Solid(board, "ARTWORK", line[1], line[2], line[3], 1)
    board.under:SetPoint("TOPLEFT", 1, -TITLE_H - TABS_H + 1)
    board.under:SetSize(LIST_W, 1)

    -- The columns' names.
    local top = -TITLE_H - TABS_H
    local function Head(text, color, left, width, justify)
        local fs = Text(board, 10, color, width, justify)
        fs:SetPoint("TOPLEFT", left, top - 5)
        fs:SetText(text)
        return fs
    end
    Head("#", "muted", 10, 22)
    Head(B.player, "muted", 63, 88)
    Head(B.total, "gold", 151, 62, "RIGHT")
    Head(B.quests, "muted", 213, 46, "RIGHT")
    Head(B.avg, "muted", 259, 36, "RIGHT")
    Head(B.byPart, "muted", BAR_LEFT + 1, nil)

    -- The players, and where the rows shown are among them.
    board.list = CreateFrame("Frame", nil, board)
    board.list:SetPoint("TOPLEFT", 0, top - HEAD_H)
    board.list:SetWidth(LIST_W)
    board.mark = Solid(board.list, "ARTWORK", 0.137, 0.204, 0.31, 1)
    board.mark:SetWidth(5)
    board.mark.host = board.list
    board.mark:Hide()

    -- What the bars' colors are, then who was refused records.
    board.legend = CreateFrame("Frame", nil, board)
    board.legend:SetSize(LIST_W, LEGEND_H)
    board.legend:SetPoint("TOPLEFT", board.list, "BOTTOMLEFT", 0, 0)
    board.over = Solid(board.legend, "ARTWORK", line[1], line[2], line[3], 1)
    board.over:SetPoint("TOPLEFT", 1, 0)
    board.over:SetSize(LIST_W, 1)
    local lx = 10
    for _, part in ipairs(PARTS) do
        local swatch = board.legend:CreateTexture(nil, "ARTWORK")
        Fade(swatch, part.top, part.bottom)
        swatch:SetSize(8, 8)
        swatch:SetPoint("LEFT", lx, 0)
        local label = Text(board.legend, 10, "muted")
        label:SetPoint("LEFT", lx + 12, 0)
        label:SetText(B[part.key])
        lx = lx + 12 + (label:GetStringWidth() or 30) + 10
    end
    board.noteMark = Text(board, 12, "red")
    board.noteMark:SetPoint("TOPLEFT", board.legend, "BOTTOMLEFT", 22, -3)
    board.noteMark:SetText("!")
    board.note = Text(board, 10, "muted", LIST_W - 50)
    board.note:SetPoint("TOPLEFT", board.legend, "BOTTOMLEFT", 34, -4)

    -- The detail of the player selected, to the right of the list: always there.
    local pane = CreateFrame("Frame", nil, board)
    pane:SetWidth(PANE_W)
    pane.rows = {}
    pane.back = pane:CreateTexture(nil, "BACKGROUND", nil, 3)
    pane.back:SetAllPoints()
    Fade(pane.back, { 0.008, 0.02, 0.043 }, FG.Skin.colors.accent, 0.45, 0.1)
    -- What it says of the player: hidden as one when the tab has nobody.
    local content = CreateFrame("Frame", nil, pane)
    content:SetAllPoints()
    pane.content = content
    pane.class = Solid(content, "ARTWORK", 0.3, 0.33, 0.4, 1)
    pane.class:SetSize(14, 14)
    pane.class:SetPoint("TOPLEFT", 10, -12)
    pane.name = Text(content, 13, "text")
    pane.name:SetPoint("LEFT", pane.class, "RIGHT", 6, 0)
    pane.who = Text(content, 10, "muted")
    pane.who:SetPoint("LEFT", pane.name, "RIGHT", 8, 0)
    pane.total = Text(content, 13, "gold", 100, "RIGHT")
    pane.total:SetPoint("TOPRIGHT", -8, -12)
    pane.summary = Text(content, 10, "muted")
    pane.summary:SetPoint("TOPLEFT", 10, -38)
    pane.bar = Bar(content, BAR_W)
    pane.bar:SetPoint("TOPRIGHT", -8, -38)
    pane.tiles = {}
    for i, label in ipairs({ B.base, B.speed, B.luck, B.deaths }) do
        local tile = CreateFrame("Frame", nil, content)
        tile.back = tile:CreateTexture(nil, "BACKGROUND", nil, 4)
        tile.back:SetAllPoints()
        Fade(tile.back, { 0.2, 0.275, 0.44 }, { 0.016, 0.035, 0.07 }, 0.55, 0.6)
        tile.label = Text(tile, 10, "muted")
        tile.label:SetPoint("TOPLEFT", 6, -5)
        tile.label:SetText(label)
        tile.value = Text(tile, 13, i == 4 and "red" or "text")
        tile.value:SetPoint("BOTTOMLEFT", 6, 5)
        pane.tiles[i] = tile
    end
    pane.stripLabel = Text(content, 10, "muted")
    pane.stripLabel:SetPoint("TOPLEFT", 10, -104)
    pane.stripLabel:SetText(B.difficulty)
    pane.strip = CreateFrame("Frame", nil, content)
    pane.strip.left = 10 + (pane.stripLabel:GetStringWidth() or 80) + 8
    pane.strip.width = math.max(40, PANE_W - 8 - pane.strip.left)
    pane.strip:SetSize(pane.strip.width, 8)
    pane.strip:SetPoint("TOPLEFT", pane.strip.left, -106)
    local track = Solid(pane.strip, "BACKGROUND", 0, 0, 0, 1)
    track:SetAllPoints()
    pane.strip.pieces = {}
    for i, c in ipairs(DIFFICULTY) do
        local piece = Solid(pane.strip, "ARTWORK", c[1], c[2], c[3], 1)
        piece:SetHeight(6)
        pane.strip.pieces[i] = piece
    end
    local qtop = -124
    pane.recent = Text(content, 10, "muted")
    pane.recent:SetPoint("TOPLEFT", 10, qtop)
    pane.recent:SetText(B.recent)
    for _, col in ipairs({ { B.time, "muted", -88 }, { B.luck, "muted", -52 }, { B.points, "gold", -16 } }) do
        local fs = Text(content, 10, col[2], 36, "RIGHT")
        fs:SetPoint("TOPRIGHT", col[3], qtop)
        fs:SetText(col[1])
    end
    local rule = Solid(content, "ARTWORK", line[1], line[2], line[3], 1)
    rule:SetPoint("TOPLEFT", 10, qtop - 16)
    rule:SetPoint("TOPRIGHT", -8, qtop - 16)
    rule:SetHeight(1)
    pane.quests = CreateFrame("Frame", nil, content)
    pane.quests:SetPoint("TOPLEFT", 10, -PANE_TOP)
    pane.quests:SetPoint("BOTTOMRIGHT", -8, PANE_BOTTOM)
    pane.mark = Solid(pane.quests, "ARTWORK", 0.137, 0.204, 0.31, 1)
    pane.mark:SetWidth(5)
    pane.mark.host = pane.quests
    pane.mark:Hide()
    pane:EnableMouseWheel(true)
    pane:SetScript("OnMouseWheel", function(_, delta)
        Stats.questOffset = math.max(0, (Stats.questOffset or 0) - (tonumber(delta) or 0) * 2)
        Stats:FillBoard()
    end)
    board.pane = pane

    board:EnableMouseWheel(true)
    board:SetScript("OnMouseWheel", function(_, delta)
        Stats.offset = math.max(0, (Stats.offset or 0) - (tonumber(delta) or 0))
        Stats:FillBoard()
    end)
    board.divider = Divider(board)
    board.grip = Grip(board)
    FG.Skin:Style(board, "panel", { board.title, board.note })
    if UISpecialFrames then table.insert(UISpecialFrames, "PathwrightLeaderboard") end
    board:Hide()
    return board
end

--- Open or close the leaderboard: it opens on you.
function Stats:ToggleBoard()
    if not self.board then self.board = BuildBoard() end
    if self.board:IsShown() then return self.board:Hide() end
    self.selected, self.questOffset = "me", 0
    self:FillBoard()
    self.board:Show()
    self:HelloAll()
end

-- Events ---------------------------------------------------------------------------------------------

if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then C_ChatInfo.RegisterAddonMessagePrefix(PREFIX) end

local scanning = false
local function ScheduleScan()
    if scanning or not seen then return end
    scanning = true
    local function Run()
        scanning = false
        FG:Try("stats", Stats.Scan, Stats, false)
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(0.5, Run)
    else
        Run()
    end
end

--- A fight begins (`npc`: the target then) or ends.
function Stats:Fight(began, npc)
    if began then
        fight = { start = self.clock(), npc = npc }
    elseif fight then
        fight.stop = self.clock()
    end
end

FG:On("PLAYER_LOGIN", function()
    FG:Try("stats", Stats.Verify, Stats)
    FG:Try("stats", Stats.SeedSpare, Stats)
    FG:Try("stats", Stats.Scan, Stats, true)
    -- The clock of the quests under way: only while logged in (from now on), in their area.
    lastTick = Stats.clock()
    if C_Timer and C_Timer.NewTicker then
        C_Timer.NewTicker(TICK, function() FG:Try("stats tick", Stats.Tick, Stats) end)
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(15, function() Stats:HelloAll() end)
        if C_Timer.NewTicker then C_Timer.NewTicker(HELLO_EVERY, function() Stats:HelloAll() end) end
    end
end)
for _, event in ipairs({ "QUEST_LOG_UPDATE", "QUEST_WATCH_UPDATE" }) do
    FG:On(event, ScheduleScan)
end
FG:On("UNIT_QUEST_LOG_CHANGED", function(unit)
    if unit == "player" then ScheduleScan() end
end)
FG:On("QUEST_TURNED_IN", function(questID)
    questID = Readable(questID)
    if not questID then return end
    FG:Try("stats turn-in", Stats.TurnedIn, Stats, questID)
    -- Not final yet: its last objective may have completed this instant. The log once more.
    local rec = Stats:Quests()[questID]
    if rec and rec.v == 2 and not rec.d and seen and seen[questID] then
        FG:Try("stats", Stats.Scan, Stats, false)
        FG:Try("stats turn-in", Stats.TurnedIn, Stats, questID)
    end
end)
FG:On("LOOT_READY", function() FG:Try("stats loot", Stats.ReadLoot, Stats) end)
FG:On("LOOT_OPENED", function() FG:Try("stats loot", Stats.ReadLoot, Stats) end)
FG:On("PARTY_KILL", function(attackerGUID, targetGUID)
    local source = Readable(attackerGUID)
    if not source or not UnitGUID then return end
    if source ~= Readable(UnitGUID("player")) and source ~= Readable(UnitGUID("pet")) then return end
    local kind, npc = FG.ParseGUID(targetGUID)
    if kind == "npc" then FG:Try("stats kill", Stats.Kill, Stats, npc, Readable(targetGUID)) end
end)
FG:On("PLAYER_REGEN_DISABLED", function()
    local kind, npc
    if UnitGUID and UnitExists and UnitExists("target") then
        kind, npc = FG.ParseGUID(UnitGUID("target"))
    end
    Stats:Fight(true, kind == "npc" and npc or nil)
end)
FG:On("PLAYER_REGEN_ENABLED", function() Stats:Fight(false) end)
FG:On("PLAYER_DEAD", function() FG:Try("stats death", Stats.Died, Stats) end)
-- Friends coming online: hello (once a minute at most each), 2 s after a burst of these events.
local helloSoon = false
local CIRCLE = { "FRIENDLIST_UPDATE", "BN_FRIEND_INFO_CHANGED", "GROUP_ROSTER_UPDATE", "GUILD_ROSTER_UPDATE" }
for _, event in ipairs(CIRCLE) do
    FG:On(event, function()
        Stats.Forget(event == "GUILD_ROSTER_UPDATE")
        if helloSoon or not (C_Timer and C_Timer.After) then return end
        helloSoon = true
        C_Timer.After(2, function()
            helloSoon = false
            Stats:HelloAll()
        end)
    end)
end
FG:On("CHAT_MSG_ADDON", function(prefix, text, channel, sender)
    if prefix ~= PREFIX then return end
    FG:Try("stats receive", Stats.Receive, Stats, text, Full(Readable(sender)), nil, Readable(channel))
end)
FG:On("BN_CHAT_MSG_ADDON", function(prefix, text, _, gameAccountID)
    if prefix ~= PREFIX or not C_BattleNet or not C_BattleNet.GetGameAccountInfoByID then return end
    local g = C_BattleNet.GetGameAccountInfoByID(gameAccountID)
    local name = g and g.characterName and Full(g.characterName, g.realmName)
    if name then FG:Try("stats receive", Stats.Receive, Stats, text, name) end
end)
FG:On("PLAYER_LOGIN", function()
    FG:OnSetting("statsShare", function(on)
        if on then Stats:HelloAll() end
    end)
    FG:OnSetting("questStats", function()
        if FG.Guide and FG.Guide.Refresh then FG.Guide:Refresh() end
    end)
end)
