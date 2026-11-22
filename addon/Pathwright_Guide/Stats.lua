-- Quest stats: how long each quest's objectives take you, how often its items drop for you, a
-- fantasy score for each quest you finish, and a leaderboard with your friends.
--
-- Time: from the first count of any of the quest's objectives (a mob killed, an item looted or
-- picked up, an object used) to the moment its last objective completes, counting only the time
-- spent logged in and in the quest's area: within AREA_YARDS of a place where one of its counts
-- happened or a place the guide gives for its objectives. A hearth to town, a trip to the
-- auction house, a logout: none of that counts. A ticker adds the time every TICK seconds, at
-- most MAX_TICK at once (a loading screen, a freeze). Without a position (an instance), the time
-- counts. A quest already under way when first seen (taken before this addon kept stats) has no
-- time and no score.
--
-- Drop rate, for each item a quest needs: of the corpses you looted of the mobs that drop it
-- (the guide's mobs for it, and any mob it came from), while you still needed it, the share that
-- had it. Corpses with nothing at all on them open no loot window: they are not counted.
--
-- Score (fantasy points), for each quest finished, see Stats.Score:
--   40 for finishing it,
--   +1 for each count of its objectives (8 kills: 8),
--   + speed: 60 x (par / your time), at most 150. Par: 20 s a kill, 20 s a corpse looted for an
--     item (the corpses you looted for it), 15 s any other count,
--   + luck, when the guide gives the item's drop chance (`dr` on its step): 20 x (your rate /
--     that chance - 1), from -20 to +30,
--   - 15 for each death while doing it. Never below 0.
--
-- Sharing (setting statsShare): your total and your finished quests go to your friends who have
-- the addon, silently, as addon messages: online WoW friends (whispers), Battle.net friends in
-- this same game (game data), and your party. Only messages from those players are taken.
-- Messages (prefix PWStats, fields joined by "|"):
--   H|1|<total>|<quests>                 hello: my total score and quests finished
--   R|<since>                            send me your quests finished after <since> (time())
--   Q|<quest>|<seconds>|<rate>|<score>|<finished at>   one quest finished (rate: % or empty)

local FG = Pathwright
local T = FG.T
local QuestLog = FG.QuestLog
local Readable = FG.Readable
local Stats = { now = time, clock = GetTime }
FG.Stats = Stats

local PREFIX = "PWStats"
local VERSION = 1
--- Quests kept per character (the oldest finished dropped beyond).
local MAX_QUESTS = 2000
--- Records sent in answer to one request, newest first.
local MAX_SENT = 150
--- Seconds between two hellos to the same player, and between two rounds of hellos.
local HELLO_AGAIN, HELLO_EVERY = 60, 900
--- Seconds between two messages sent.
local SEND_GAP = 0.25
--- Yards from the quest's places within which its time counts; places closer than MERGE_YARDS to
--- one kept already are not kept again, at most MAX_PLACES of them.
local AREA_YARDS, MERGE_YARDS, MAX_PLACES = 300, 60, 16
--- Seconds between two additions of time, and the most one adds.
local TICK, MAX_TICK = 5, 10

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

-- Records ---------------------------------------------------------------------------------------

local function DB()
    PathwrightDB.stats = PathwrightDB.stats or {}
    local db = PathwrightDB.stats
    db.peers = db.peers or {}
    return db
end

--- This character's quest records: questID -> record.
function Stats:Quests()
    local char = PathwrightDB and PathwrightDB.characters and PathwrightDB.characters[FG:CharacterKey()]
    if not char then return {} end
    char.quests = char.quests or {}
    return char.quests
end

--- Seconds a record's objectives took, in its area (nil before it starts; running: so far).
function Stats.Seconds(rec)
    if not rec or not rec.s then return nil end
    return rec.t or 0
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

local lastTick -- clock of the last addition of time (nil before the first, after login)

--- Add the time since the last tick to the quests under way whose area the player is in.
function Stats:Tick()
    local now = self.clock()
    local dt = lastTick and math.max(0, math.min(MAX_TICK, now - lastTick)) or 0
    lastTick = now
    if dt == 0 then return end
    for _, rec in pairs(self:Quests()) do
        if rec.s and not rec.e and not rec.p and self.InArea(rec) then rec.t = (rec.t or 0) + dt end
    end
end

--- Drop rate of a record: share (0-1) over all its items, the corpses counted, nil without any.
function Stats.Rate(rec, item)
    local c, d = 0, 0
    for name, l in pairs(rec and rec.loot or {}) do
        if not item or name == item then
            c, d = c + (l.c or 0), d + (l.d or 0)
        end
    end
    if c == 0 then return nil end
    return d / c, c, d
end

--- The fantasy points of a finished record (see the top of the file); `dr`: the item's drop chance
--- (0-1) when the guide gives it.
function Stats.Score(rec, dr)
    if not rec or not rec.e or rec.p then return 0 end
    local counts = rec.need or 0
    local points = 40 + counts
    -- Par: 20 s a kill or a corpse looted for an item, 15 s any other count.
    local corpses = 0
    for _, l in pairs(rec.loot or {}) do
        corpses = corpses + (l.c or 0)
    end
    local par = 20 * ((rec.kills or 0) + corpses) + 15 * math.max(0, counts - (rec.kills or 0) - (rec.items or 0))
    local seconds = Stats.Seconds(rec)
    if par > 0 and seconds and seconds > 0 then
        points = points + math.min(150, 60 * par / seconds)
    elseif par > 0 then
        points = points + 60
    end
    local rate = Stats.Rate(rec)
    if dr and dr > 0 and rate then points = points + math.max(-20, math.min(30, 20 * (rate / dr - 1))) end
    points = points - 15 * (rec.deaths or 0)
    return math.max(0, math.floor(points + 0.5))
end

--- My total score and quests finished (this character).
function Stats:Total()
    local total, count = 0, 0
    for _, rec in pairs(self:Quests()) do
        if rec.e and not rec.p then
            total, count = total + (rec.sc or 0), count + 1
        end
    end
    return total, count
end

--- Keep at most MAX_QUESTS records: the oldest finished go first.
local function Trim(quests)
    local n, finished = 0, {}
    for id, rec in pairs(quests) do
        n = n + 1
        if rec.e then finished[#finished + 1] = { id = id, e = rec.e } end
    end
    if n <= MAX_QUESTS then return end
    table.sort(finished, function(a, b) return a.e < b.e end)
    for i = 1, math.min(#finished, n - MAX_QUESTS) do
        quests[finished[i].id] = nil
    end
end

-- Objectives --------------------------------------------------------------------------------------

--- The item objectives still needed, by item name (lowercase): { quest, index }.
Stats.wanted = {}
--- The counts seen last, questID -> { have by objective }; nil before the first look at the log.
local seen

--- The guide's drop chance and mobs of a quest's item, from its step.
local function GuideItem(questID, name)
    local route = FG.Guide and FG.Guide:Route()
    for _, s in ipairs(route and route.steps or {}) do
        if s.q == questID and s.e == "item" and s.n and s.n:lower() == name then return s end
    end
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

--- Apply a look at the quest log: `log` = questID -> list of { have, need, finished, type, text }.
--- `first`: the first look (login, reload): counts already there start nothing.
function Stats:Apply(log, first, now)
    now = now or self.now()
    local quests = self:Quests()
    local wanted = {}
    for questID, objectives in pairs(log) do
        local rec = quests[questID]
        local before = seen and seen[questID]
        local total, allDone, counts = 0, #objectives > 0, 0
        for index, o in ipairs(objectives) do
            local need = tonumber(o.need) or 0
            local have = math.min(tonumber(o.have) or 0, need)
            total = total + need
            counts = counts + have
            allDone = allDone and (o.finished == true or (need > 0 and have >= need))
            local was = before and before[index] or (first and have) or 0
            if have > was and not (rec and rec.e) then
                if not rec then
                    rec = {}
                    quests[questID] = rec
                end
                if not rec.s then
                    -- Its clock starts: the time before (other quests ticking) is not its own.
                    self:Tick()
                    rec.s, rec.t = now, 0
                    self:SeedArea(questID, rec)
                end
                -- Where this count happened belongs to the quest's area.
                self.AddPlace(rec, self.where())
                if o.type == "monster" then rec.kills = (rec.kills or 0) + (have - was) end
                if o.type == "item" then rec.items = (rec.items or 0) + (have - was) end
            end
            if o.type == "item" and not (o.finished or have >= need) and o.text then
                local name = o.text:gsub("%s*:?%s*%d+%s*/%s*%d+%s*$", ""):gsub("^%d+%s*/%s*%d+%s+", ""):lower()
                if name ~= "" then wanted[name] = { quest = questID, index = index } end
            end
        end
        -- Under way already when first seen, without a record: no time, no score.
        if first and not rec and counts > 0 then
            rec = { p = true }
            quests[questID] = rec
        end
        if rec and allDone and total > 0 and not rec.e then
            self:Tick()
            rec.e = now
            rec.need = total
            if not rec.s then rec.s = now end
            local main = next(rec.loot or {})
            local step = main and GuideItem(questID, main)
            rec.sc = self.Score(rec, step and tonumber(step.dr))
            if not rec.p then self:Finished(questID, rec) end
        end
        local counts2 = {}
        for index, o in ipairs(objectives) do
            counts2[index] = tonumber(o.have) or 0
        end
        log[questID] = counts2
    end
    -- Abandoned while under way: forgotten.
    for questID, rec in pairs(quests) do
        if not rec.e and not log[questID] and seen and seen[questID] then quests[questID] = nil end
    end
    seen = log
    self.wanted = wanted
    Trim(quests)
end

--- Read the quest log and apply it.
function Stats:Scan(first)
    if not QuestLog.GetQuestObjectives or not QuestLog.GetNumQuestLogEntries then return end
    local log = {}
    for i = 1, QuestLog.GetNumQuestLogEntries() do
        local info = QuestLog.GetInfo and QuestLog.GetInfo(i)
        local questID = info and not info.isHeader and Readable(info.questID)
        if questID and questID > 0 then
            local list = {}
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

-- Loot ---------------------------------------------------------------------------------------------

--- Count the corpses of a loot window for the items still needed: `corpses` = list of { npc,
--- items = { [lowercase name] = quantity } }.
function Stats:Loot(corpses)
    local quests = self:Quests()
    for name, w in pairs(self.wanted) do
        -- The loot window comes before the quest log counts the item: its record may start here.
        local rec = quests[w.quest]
        if not rec then
            rec = {}
            quests[w.quest] = rec
        end
        if not rec.e and not rec.p then
            rec.src = rec.src or {}
            local step = GuideItem(w.quest, name)
            for _, npc in ipairs(step and step.mi or {}) do
                rec.src[npc] = true
            end
            for _, corpse in ipairs(corpses) do
                local has = corpse.items[name]
                if has then rec.src[corpse.npc] = true end
                if rec.src[corpse.npc] then
                    rec.loot = rec.loot or {}
                    local l = rec.loot[name] or { c = 0, d = 0 }
                    rec.loot[name] = l
                    l.c = l.c + 1
                    if has then l.d = l.d + 1 end
                end
            end
        end
    end
end

local looted, lootedCount = {}, 0 -- corpse GUIDs counted already (the window opened again)

--- Read the loot window (before fast loot takes it, Automation.lua calls this first).
function Stats:ReadLoot()
    if not GetLootSourceInfo or not GetNumLootItems or not next(self.wanted) then return end
    local byGuid, order = {}, {}
    for slot = 1, GetNumLootItems() do
        local link = GetLootSlotLink and GetLootSlotLink(slot)
        local name = link and link:match("%[(.-)%]")
        local sources = { GetLootSourceInfo(slot) }
        for i = 1, #sources, 2 do
            local guid = Readable(sources[i])
            if guid and not looted[guid] then
                local kind, id = FG.ParseGUID(guid)
                if kind == "npc" and id then
                    local corpse = byGuid[guid]
                    if not corpse then
                        corpse = { npc = id, items = {} }
                        byGuid[guid] = corpse
                        order[#order + 1] = guid
                    end
                    if name then corpse.items[name:lower()] = (tonumber(Readable(sources[i + 1])) or 1) end
                end
            end
        end
    end
    local corpses = {}
    for _, guid in ipairs(order) do
        looted[guid] = true
        lootedCount = lootedCount + 1
        corpses[#corpses + 1] = byGuid[guid]
    end
    if lootedCount > 500 then
        wipe(looted)
        lootedCount = 0
    end
    if corpses[1] then self:Loot(corpses) end
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
--- item, the score once finished. Nil when there is nothing yet (or stats are off).
function Stats:StepLine(step)
    if not FG:Get("questStats") or not step or not step.q then return nil end
    local rec = self:Quests()[step.q]
    if not rec or rec.p or not rec.s then return nil end
    local parts = {}
    if step.e == "item" and step.n then
        local rate = self.Rate(rec, step.n:lower())
        if rate then parts[#parts + 1] = string.format(L.drop, math.floor(rate * 100 + 0.5)) end
    end
    local seconds = self.Seconds(rec)
    if seconds then parts[#parts + 1] = Clock(seconds) end
    if rec.e and rec.sc then parts[#parts + 1] = string.format(L.pts, rec.sc) end
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
        if q then others[#others + 1] = { name = name, s = q.s or 0, t = q.t, r = q.r } end
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

--- Who we share with now: { whispers = { full names }, bnet = { gameAccountID = full name } }
--- (online WoW friends, Battle.net friends in this game), and the party's members by name.
function Stats.Friends()
    local out = { whispers = {}, bnet = {}, allowed = {} }
    if C_FriendList and C_FriendList.GetNumFriends then
        for i = 1, C_FriendList.GetNumFriends() or 0 do
            local info = C_FriendList.GetFriendInfoByIndex(i)
            local name = info and Full(Readable(info.name))
            if name then
                out.allowed[name] = true
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
                    out.allowed[name] = true
                end
            end
        end
    end
    for i = 1, GetNumSubgroupMembers and GetNumSubgroupMembers() or 0 do
        local name, realm = UnitName("party" .. i)
        name = Full(Readable(name), Readable(realm))
        if name then out.allowed[name] = true end
    end
    return out
end

local queue, sending = {}, false

local function Flush()
    sending = false
    local m = table.remove(queue, 1)
    if not m then return end
    if m.bnet and BNSendGameData then
        BNSendGameData(m.bnet, PREFIX, m.text)
    elseif m.channel and C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(PREFIX, m.text, m.channel, m.target)
    end
    if queue[1] and C_Timer and C_Timer.After then
        sending = true
        C_Timer.After(SEND_GAP, Flush)
    elseif queue[1] then
        Flush()
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
end

function Stats.Record(questID, rec)
    local rate = Stats.Rate(rec)
    return string.format(
        "Q|%d|%d|%s|%d|%d",
        questID,
        Stats.Seconds(rec) or 0,
        rate and tostring(math.floor(rate * 100 + 0.5)) or "",
        rec.sc or 0,
        rec.e or 0
    )
end

function Stats:Hello(only)
    local total, count = self:Total()
    self:Send(string.format("H|%d|%d|%d", VERSION, total, count), only)
end

--- A quest finished: tell the friends.
function Stats:Finished(questID, rec)
    self:Send(self.Record(questID, rec))
    self:Hello()
end

local helloAt = {} -- full name -> when we last said hello to them

--- A message from `sender` (full name), when they are a friend or in the party.
function Stats:Receive(text, sender, friends)
    friends = friends or self.Friends()
    if type(text) ~= "string" or not sender or sender == Me() or not friends.allowed[sender] then return end
    local kind, a, b, c, d, e = strsplit("|", text)
    local peers = DB().peers
    local peer = peers[sender] or { q = {} }
    peers[sender] = peer
    peer.at = self.now()
    if kind == "H" then
        peer.total, peer.count = tonumber(b) or 0, tonumber(c) or 0
        local have = 0
        for _ in pairs(peer.q) do
            have = have + 1
        end
        if peer.count > have then self:Send("R|" .. (peer.last or 0), sender) end
        if (helloAt[sender] or 0) + HELLO_AGAIN < self.now() then
            helloAt[sender] = self.now()
            self:Hello(sender)
        end
    elseif kind == "R" then
        local since = tonumber(a) or 0
        local list = {}
        for id, rec in pairs(self:Quests()) do
            if rec.e and not rec.p and rec.e > since then list[#list + 1] = { id = id, rec = rec } end
        end
        table.sort(list, function(x, y) return x.rec.e > y.rec.e end)
        for i = 1, math.min(MAX_SENT, #list) do
            self:Send(self.Record(list[i].id, list[i].rec), sender)
        end
    elseif kind == "Q" then
        local questID = tonumber(a)
        if not questID then return end
        local finishedAt = tonumber(e) or 0
        peer.q[questID] = { t = tonumber(b), r = tonumber(c), s = tonumber(d) or 0, e = finishedAt }
        peer.last = math.max(peer.last or 0, finishedAt)
    end
    if self.board and self.board:IsShown() then self:FillBoard() end
end

--- Hello to the friends online now (those we did not greet lately).
function Stats:HelloAll()
    if not FG:Get("statsShare") then return end
    local friends = self.Friends()
    local now = self.now()
    for _, name in ipairs(friends.whispers) do
        if (helloAt[name] or 0) + HELLO_AGAIN < now then
            helloAt[name] = now
            self:Hello(name)
        end
    end
    for _, name in pairs(friends.bnet) do
        if (helloAt[name] or 0) + HELLO_AGAIN < now then
            helloAt[name] = now
            self:Hello(name)
        end
    end
end

-- The leaderboard ------------------------------------------------------------------------------

local ROW, WIDTH = 20, 280

--- The board's lines: me and every friend seen, by total score.
function Stats:Standings()
    local total, count = self:Total()
    local list = { { name = UnitName("player"), total = total, count = count, me = true } }
    for name, peer in pairs(DB().peers) do
        list[#list + 1] = { name = (name:gsub("%-.*", "")), total = peer.total or 0, count = peer.count or 0 }
    end
    table.sort(list, function(a, b)
        if a.total ~= b.total then return a.total > b.total end
        return a.name < b.name
    end)
    return list
end

local function BoardRow(i)
    local board = Stats.board
    local r = board.rows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, board)
    r:SetSize(WIDTH - 20, ROW)
    r.rank = FG.Skin:Text(r, 11, "muted")
    r.rank:SetPoint("LEFT", 0, 0)
    r.rank:SetWidth(22)
    r.name = FG.Skin:Text(r, 12, "text")
    r.name:SetPoint("LEFT", 24, 0)
    r.name:SetWidth(110)
    r.name:SetWordWrap(false)
    r.total = FG.Skin:Text(r, 12, "gold")
    r.total:SetPoint("LEFT", 136, 0)
    r.more = FG.Skin:Text(r, 9, "dim")
    r.more:SetPoint("RIGHT", 0, 0)
    board.rows[i] = r
    return r
end

function Stats:FillBoard()
    local board = self.board
    if not board then return end
    local list = self:Standings()
    for i, e in ipairs(list) do
        local r = BoardRow(i)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", 10, -30 - (i - 1) * ROW)
        r.rank:SetText(i .. ".")
        r.name:SetText(e.me and (e.name .. " (" .. L.you .. ")") or e.name)
        local c = FG.Skin.colors[e.me and "green" or "text"]
        r.name:SetTextColor(c[1], c[2], c[3])
        r.total:SetText(string.format(L.pts, e.total))
        r.more:SetText(
            string.format(L.quests, e.count)
                .. (e.count > 0 and ("  " .. string.format(L.avg, math.floor(e.total / e.count + 0.5))) or "")
        )
        r:Show()
    end
    for i = #list + 1, #board.rows do
        board.rows[i]:Hide()
    end
    board.empty:SetShown(#list == 1)
    board:SetHeight(40 + #list * ROW + (#list == 1 and 34 or 0))
end

--- Open or close the leaderboard.
function Stats:ToggleBoard()
    if not self.board then
        local board = CreateFrame("Frame", "PathwrightLeaderboard", FG.UIRoot, "BackdropTemplate")
        board:SetWidth(WIDTH)
        board:SetPoint("CENTER")
        board:SetFrameStrata("DIALOG")
        board:SetClampedToScreen(true)
        FG:Draggable(board)
        board.rows = {}
        board.title = FG.Skin:Text(board, 13, "text")
        board.title:SetPoint("TOPLEFT", 10, -9)
        board.title:SetText(L.board)
        board.close = CreateFrame("Button", nil, board, "UIPanelCloseButton")
        board.close:SetPoint("TOPRIGHT", 2, 2)
        board.empty = FG.Skin:Text(board, 10, "muted")
        board.empty:SetPoint("BOTTOMLEFT", 10, 10)
        board.empty:SetPoint("RIGHT", -10, 0)
        board.empty:SetText(L.none)
        FG.Skin:Style(board, "panel", { board.title, board.empty })
        if UISpecialFrames then table.insert(UISpecialFrames, "PathwrightLeaderboard") end
        board:Hide()
        self.board = board
    end
    if self.board:IsShown() then return self.board:Hide() end
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

FG:On("PLAYER_LOGIN", function()
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
FG:On("LOOT_READY", function() FG:Try("stats loot", Stats.ReadLoot, Stats) end)
FG:On("LOOT_OPENED", function() FG:Try("stats loot", Stats.ReadLoot, Stats) end)
FG:On("PLAYER_DEAD", function()
    for _, rec in pairs(Stats:Quests()) do
        if rec.s and not rec.e and not rec.p then rec.deaths = (rec.deaths or 0) + 1 end
    end
end)
-- Friends coming online: hello (once a minute at most each), 2 s after a burst of these events.
local helloSoon = false
for _, event in ipairs({ "FRIENDLIST_UPDATE", "BN_FRIEND_INFO_CHANGED", "GROUP_ROSTER_UPDATE" }) do
    FG:On(event, function()
        if helloSoon or not (C_Timer and C_Timer.After) then return end
        helloSoon = true
        C_Timer.After(2, function()
            helloSoon = false
            Stats:HelloAll()
        end)
    end)
end
FG:On("CHAT_MSG_ADDON", function(prefix, text, _, sender)
    if prefix ~= PREFIX then return end
    FG:Try("stats receive", Stats.Receive, Stats, text, Full(Readable(sender)))
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
