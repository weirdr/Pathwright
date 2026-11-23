-- Quest progress shared with the group the way Questie shares it, so that party members running
-- Questie see ours (its map pins, tooltips and tracker show other players' progress). Nothing is
-- sent while Questie itself runs here: it shares already.
--
-- Questie's messages, on the addon prefix "questie" (QuestieComms, message version 5):
--   1  a quest's progress: { quest = { id, objectives = { [i] = { id, typ, fin, ful, req } } } }
--   2  a quest left the log: { id = questID }
--   11 "send me your quests" (a player joining or reloading): answered in a whisper with 12
--   12 a block of the whole log, flat: { [1] = { count, questID, objectiveCount,
--      (objectiveID or 0, type byte, fulfilled, required) * objectiveCount, ... } }
-- every one with ver (Questie's version), msgVer and msgId. Our ver is kept low: a Questie
-- older than ours would tell its player to update. Objective IDs (the mob, item or object of the
-- objective, as Questie's database has them) come from the guides; without one, Questie still
-- takes the counts (it does so for its own objectives without an ID).
--
-- The wire format (Questie's QuestieSerializer, "1short" stream), written here from its
-- description: Serialize(t) writes the pair (1, t). A value starts with a type byte: 32 + n for
-- an integer n < 222; 12/13 a byte, 14/15 a short, 2/3 an int, 4/5 a long (positive/negative,
-- big-endian); 6 a float (IEEE 754 single); 7 a string (length byte), 8 a long string (length
-- short); 9 the hash of a string met before in the message; 10/11 a table (pair count byte/short)
-- of key, value pairs; 20/21/22 an array (count byte/short/int) of values; 16/17 false/true;
-- 1, 18, 19 nil. Pairs whose value is false or nil are left out. The "1short" stream then escapes
-- every byte so that none is 0: 0 -> 238, 237 -> 237 1, 238 -> 237 2.

local FG = Pathwright
local QuestLog = FG.QuestLog
local Readable = FG.Readable

local PREFIX = "questie"
local MSG_VERSION = 5
--- Our Questie version for its peers: below any Questie that speaks message version 5.
local VERSION = "1.0.0"
local UPDATE, REMOVE, REQUEST_LIST, FULL_LIST = 1, 2, 11, 12
--- Questie stops at this many group members (and in battlegrounds).
local MAX_GROUP = 15
--- A block of the full list stays under this many bytes (Questie's own limit, room for the rest).
local BLOCK_BYTES = 200
--- Seconds between two blocks of the full list.
local BLOCK_GAP = 1

local QuestieShare = { sent = {}, grouped = false }
FG.QuestieShare = QuestieShare

-- The serializer -------------------------------------------------------------------------

local Writer = {}
Writer.__index = Writer

local function NewWriter() return setmetatable({ out = {} }, Writer) end

function Writer:Byte(v)
    local out = self.out
    if v == 0 then
        out[#out + 1] = 238
    elseif v == 237 then
        out[#out + 1] = 237
        out[#out + 1] = 1
    elseif v == 238 then
        out[#out + 1] = 237
        out[#out + 1] = 2
    else
        out[#out + 1] = v
    end
end

function Writer:Bytes(v, count)
    for shift = count - 1, 0, -1 do
        self:Byte(math.floor(v / 2 ^ (8 * shift)) % 256)
    end
end

local function IsArray(t)
    local n = 0
    for _ in pairs(t) do
        n = n + 1
    end
    for i = 1, n do
        if t[i] == nil then return false, n end
    end
    return true, n
end

function Writer:Value(v)
    local kind = type(v)
    if kind == "number" then
        if v % 1 ~= 0 then error("QuestieShare: no floats in our packets") end
        local sign = v < 0 and 1 or 0
        local a = math.abs(v)
        if sign == 0 and a < 222 then
            self:Byte(32 + a)
        elseif a < 255 then
            self:Byte(12 + sign)
            self:Byte(a)
        elseif a < 65530 then
            self:Byte(14 + sign)
            self:Bytes(a, 2)
        elseif a <= 2147483646 then
            self:Byte(2 + sign)
            self:Bytes(a, 4)
        else
            self:Byte(4 + sign)
            self:Bytes(a, 8)
        end
    elseif kind == "string" then
        if #v > 254 then
            self:Byte(8)
            self:Bytes(#v, 2)
        else
            self:Byte(7)
            self:Byte(#v)
        end
        for i = 1, #v do
            self:Byte(v:byte(i))
        end
    elseif kind == "boolean" then
        self:Byte(v and 17 or 16)
    elseif kind == "table" then
        local array, n = IsArray(v)
        if array then
            self:Byte(n > 254 and 21 or 20)
            self:Bytes(n, n > 254 and 2 or 1)
            for i = 1, n do
                self:Value(v[i])
            end
        else
            -- Pairs with a false value are not written (as Questie does), nor counted.
            local keys = {}
            for k, x in pairs(v) do
                if x then table.insert(keys, k) end
            end
            table.sort(keys, function(a, b)
                if type(a) == type(b) then return a < b end
                return type(a) == "number"
            end)
            self:Byte(#keys > 254 and 11 or 10)
            self:Bytes(#keys, #keys > 254 and 2 or 1)
            for _, k in ipairs(keys) do
                self:Value(k)
                self:Value(v[k])
            end
        end
    else
        self:Byte(1)
    end
end

--- A packet as Questie writes it: the pair (1, packet), escaped.
function QuestieShare.Serialize(packet)
    local w = NewWriter()
    w:Value(1)
    w:Value(packet)
    local chars = {}
    for i, b in ipairs(w.out) do
        chars[i] = string.char(b)
    end
    return table.concat(chars)
end

--- Questie's string hash (31 * h + byte, from 5381, on 32 bits).
local function Hash(s)
    local h = 5381
    for i = 1, #s do
        h = (31 * h + s:byte(i)) % 4294967296
    end
    return h
end

--- Read a message (nil when it is not one).
function QuestieShare.Deserialize(data)
    if type(data) ~= "string" or data == "" then return nil end
    local pos, hashes = 1, {}
    local function Byte()
        local b = data:byte(pos)
        if not b then error("end of message") end
        pos = pos + 1
        if b == 238 then return 0 end
        if b == 237 then
            local c = data:byte(pos)
            pos = pos + 1
            if c == 1 then return 237 end
            if c == 2 then return 238 end
            error("bad escape")
        end
        return b
    end
    local function Bytes(count)
        local v = 0
        for _ = 1, count do
            v = v * 256 + Byte()
        end
        return v
    end
    local function Seen(s)
        if type(s) == "string" then
            local h = Hash(s)
            if hashes[h] == nil then hashes[h] = s end
        end
        return s
    end
    local Read
    local function String(len)
        local chars = {}
        for i = 1, len do
            chars[i] = string.char(Byte())
        end
        return table.concat(chars)
    end
    local function Table(count)
        local t = {}
        for _ = 1, count do
            local k = Seen(Read())
            local v = Seen(Read())
            if k ~= nil then t[k] = v end
        end
        return t
    end
    local function Array(count)
        local t = {}
        for i = 1, count do
            t[i] = Seen(Read())
        end
        return t
    end
    local READ = {
        [2] = function() return Bytes(4) end,
        [3] = function() return -Bytes(4) end,
        [4] = function() return Bytes(8) end,
        [5] = function() return -Bytes(8) end,
        [6] = function()
            local bits = Bytes(4)
            local sign = bits >= 2147483648 and -1 or 1
            local expo = math.floor(bits / 8388608) % 256
            local mant = bits % 8388608
            if expo == 0 and mant == 0 then return 0 end
            return sign * (1 + mant / 8388608) * 2 ^ (expo - 127)
        end,
        [7] = function() return String(Byte()) end,
        [8] = function() return String(Bytes(2)) end,
        [9] = function() return hashes[Bytes(4)] end,
        [10] = function() return Table(Byte()) end,
        [11] = function() return Table(Bytes(2)) end,
        [12] = function() return Byte() end,
        [13] = function() return -Byte() end,
        [14] = function() return Bytes(2) end,
        [15] = function() return -Bytes(2) end,
        [16] = function() return false end,
        [17] = function() return true end,
        [20] = function() return Array(Byte()) end,
        [21] = function() return Array(Bytes(2)) end,
        [22] = function() return Array(Bytes(4)) end,
    }
    Read = function()
        local typ = Byte()
        if typ > 31 then return typ - 32 end
        local f = READ[typ]
        return f and f() or nil
    end
    local ok, root = pcall(Table, 1)
    if not ok or type(root) ~= "table" then return nil end
    return root[1]
end

-- The player's quests --------------------------------------------------------------------

--- The objective IDs the guides know: questID -> { [index] = mob, item or object ID }.
local function GuideObjectiveIDs()
    local ids = {}
    for _, route in pairs(FG.Routes or {}) do
        for _, step in ipairs(type(route) == "table" and route.steps or {}) do
            if
                step.k == "objective"
                and step.q
                and step.o
                and step.id
                and (step.e == "npc" or step.e == "item" or step.e == "object")
            then
                ids[step.q] = ids[step.q] or {}
                ids[step.q][step.o] = ids[step.q][step.o] or step.id
            end
        end
    end
    return ids
end

--- The quests in the log: { questID }.
local function LogQuests()
    local list = {}
    for index = 1, QuestLog.GetNumQuestLogEntries() or 0 do
        local info = QuestLog.GetInfo(index)
        if info and not info.isHeader and info.questID and info.questID > 0 then table.insert(list, info.questID) end
    end
    return list
end

--- A quest's objectives as Questie sends them: { { id, typ (its first letter), fin, ful, req } }.
function QuestieShare.Objectives(questID, ids)
    local out = {}
    local result = C_QuestLog and C_QuestLog.GetQuestObjectives and Readable(C_QuestLog.GetQuestObjectives(questID))
    for index, o in ipairs(type(result) == "table" and result or {}) do
        o = Readable(o)
        if type(o) == "table" then
            local typ = Readable(o.type)
            out[index] = {
                id = ids and ids[index] or nil,
                typ = type(typ) == "string" and typ:sub(1, 1) or "m",
                fin = Readable(o.finished) and true or false,
                ful = Readable(o.numFulfilled) or 0,
                req = Readable(o.numRequired) or 0,
            }
        end
    end
    return out
end

-- Sending --------------------------------------------------------------------------------

local function QuestieRunsHere()
    local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
    return loaded and loaded("Questie") and true or false
end

--- Where the group's messages go, nil when not grouped or not to be sent.
local function Channel()
    if not IsInGroup() then return nil end
    if (GetNumGroupMembers() or 0) > MAX_GROUP then return nil end
    if UnitInBattleground and UnitInBattleground("player") then return nil end
    if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
    return IsInRaid() and "RAID" or "PARTY"
end

local function Enabled() return FG:Get("questieShare") and not QuestieRunsHere() end

local function Packet(id) return { ver = VERSION, msgVer = MSG_VERSION, msgId = id } end

local function Send(packet, channel, target)
    local data = QuestieShare.Serialize(packet)
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(PREFIX, data, channel, target)
    elseif SendAddonMessage then
        SendAddonMessage(PREFIX, data, channel, target)
    end
    return data
end

--- A quest's objectives, as one comparable text.
local function Signature(objectives)
    local parts = {}
    for i, o in ipairs(objectives) do
        parts[i] = (o.fin and 1 or 0) .. ":" .. o.ful .. "/" .. o.req
    end
    return table.concat(parts, ",")
end

--- Send what changed in the log since the last time (a quest's progress, a quest gone);
--- `silent`: only take the log as it is (at login, the whole log goes in one go instead).
function QuestieShare:Update(silent)
    local channel = not silent and Enabled() and Channel()
    local ids = GuideObjectiveIDs()
    local now = {}
    for _, questID in ipairs(LogQuests()) do
        local objectives = QuestieShare.Objectives(questID, ids[questID])
        local signature = Signature(objectives)
        now[questID] = signature
        if channel and self.sent[questID] ~= signature then
            local packet = Packet(UPDATE)
            packet.quest = { id = questID, objectives = objectives }
            Send(packet, channel)
        end
    end
    for questID in pairs(self.sent) do
        if not now[questID] and channel then
            local packet = Packet(REMOVE)
            packet.id = questID
            Send(packet, channel)
        end
    end
    self.sent = now
end

--- The whole log in blocks (message 12), to the group or whispered to `target`.
function QuestieShare:SendLog(channel, target)
    if not channel then return end
    local ids = GuideObjectiveIDs()
    local blocks, block, count = {}, { 0 }, 0
    for _, questID in ipairs(LogQuests()) do
        local entry = { questID, 0 }
        for _, o in ipairs(QuestieShare.Objectives(questID, ids[questID])) do
            entry[2] = entry[2] + 1
            table.insert(entry, o.id or 0)
            table.insert(entry, o.typ:byte())
            table.insert(entry, o.ful)
            table.insert(entry, o.req)
        end
        for _, v in ipairs(entry) do
            table.insert(block, v)
        end
        count = count + 1
        block[1] = count
        if #QuestieShare.Serialize(block) > BLOCK_BYTES then
            table.insert(blocks, block)
            block, count = { 0 }, 0
        end
    end
    if count > 0 then table.insert(blocks, block) end
    for i, b in ipairs(blocks) do
        local function Go()
            local packet = Packet(FULL_LIST)
            packet[1] = b
            Send(packet, channel, target)
        end
        if i == 1 or not (C_Timer and C_Timer.After) then
            Go()
        else
            C_Timer.After((i - 1) * BLOCK_GAP, Go)
        end
    end
    return blocks
end

--- Ask the group's Questie players for their whole logs (message 11; they answer with 12),
--- for the guide's party line. Whether or not we share ours.
function QuestieShare:Ask()
    local channel = Channel()
    if not channel then return end
    Send(Packet(REQUEST_LIST), channel)
end

-- Receiving ------------------------------------------------------------------------------

local function FromGroup(sender)
    if not sender then return false end
    local party = UnitInParty and UnitInParty(sender)
    local raid = UnitInRaid and UnitInRaid(sender)
    return (party or raid) and true or false
end

--- A Questie message from the group: its request for our quests is answered.
function QuestieShare:Receive(message, channel, sender)
    local me = GetUnitName and GetUnitName("player", true)
    if not Enabled() or sender == me or sender == UnitName("player") then return end
    if not FromGroup(sender) then return end
    local packet = QuestieShare.Deserialize(message)
    if type(packet) ~= "table" or type(packet.msgVer) ~= "number" then return end
    if math.floor(packet.msgVer) ~= MSG_VERSION then return end
    if packet.msgId == REQUEST_LIST then self:SendLog("WHISPER", sender) end
end

--- Questie players' progress, kept for the guide's party line (Party:Members): their updates,
--- their whole logs, the quests they no longer have. Read whether or not we share ours.
function QuestieShare:Store(message, sender)
    local Party = FG.Party
    if not Party or not sender or not FromGroup(sender) then return end
    local name = Ambiguate and Ambiguate(sender, "short") or sender
    if name == UnitName("player") then return end
    local packet = QuestieShare.Deserialize(message)
    if type(packet) ~= "table" or type(packet.msgVer) ~= "number" then return end
    if packet.msgId == UPDATE and type(packet.quest) == "table" then
        local counts = {}
        for i, o in ipairs(type(packet.quest.objectives) == "table" and packet.quest.objectives or {}) do
            counts[i] = o.fin and "x" or tostring(tonumber(o.ful) or 0)
        end
        Party:Store(name, tonumber(packet.quest.id), counts)
    elseif packet.msgId == REMOVE then
        Party:Forget(name, tonumber(packet.id))
    elseif packet.msgId == FULL_LIST and type(packet[1]) == "table" then
        -- { count, quest, objectives n, (id, type, fulfilled, required) x n, quest... }
        local b, at = packet[1], 2
        for _ = 1, tonumber(b[1]) or 0 do
            local questID, n = tonumber(b[at]), tonumber(b[at + 1]) or 0
            local counts = {}
            for i = 1, n do
                local base = at + 2 + (i - 1) * 4
                local ful, req = tonumber(b[base + 2]) or 0, tonumber(b[base + 3]) or 0
                counts[i] = (req > 0 and ful >= req) and "x" or tostring(ful)
            end
            Party:Store(name, questID, counts)
            at = at + 2 + n * 4
        end
    end
    if FG.Nameplates then FG.Nameplates:Refresh() end
    if FG.Guide and FG.Guide.Refresh then FG.Guide:Refresh() end
end

-- Events ---------------------------------------------------------------------------------

local pending = false
local function Later()
    if pending then return end
    pending = true
    local function Run()
        pending = false
        QuestieShare:Update()
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(0.5, Run)
    else
        Run()
    end
end

FG:On("PLAYER_LOGIN", function()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then C_ChatInfo.RegisterAddonMessagePrefix(PREFIX) end
    QuestieShare.grouped = IsInGroup() and true or false
    QuestieShare:Update(true)
    -- Logged in (or reloaded) in a group: the whole log to its Questie players.
    if QuestieShare.grouped and Enabled() then
        local function Go() QuestieShare:SendLog(Channel()) end
        if C_Timer and C_Timer.After then
            C_Timer.After(3, Go)
        else
            Go()
        end
    end
end)
FG:On("QUEST_LOG_UPDATE", Later)
FG:On("CHAT_MSG_ADDON", function(prefix, message, channel, sender)
    if prefix == PREFIX then
        QuestieShare:Receive(message, channel, sender)
        FG:Try("questie progress", QuestieShare.Store, QuestieShare, message, sender)
    end
end)
-- Joining a group: the whole log to the Questie players in it.
FG:On("GROUP_ROSTER_UPDATE", function()
    local grouped = IsInGroup() and true or false
    if grouped and not QuestieShare.grouped and Enabled() then
        local function Go() QuestieShare:SendLog(Channel()) end
        if C_Timer and C_Timer.After then
            C_Timer.After(2, Go)
        else
            Go()
        end
    end
    QuestieShare.grouped = grouped
end)
