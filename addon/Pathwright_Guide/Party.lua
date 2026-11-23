-- Group sync: members running Pathwright send their quest progress (objectives fulfilled) to
-- the party, on its own: Questie is not needed. Questie players' progress comes in too, through
-- QuestieShare.lua (which also answers them). The tracker shows theirs next to each objective,
-- the guide a line under each objective step (Party:Members).

local FG = Pathwright
local QuestLog = FG.QuestLog

local PREFIX = "PWSYNC1"
local Party = { progress = {}, updates = {} }
FG.Party = Party

if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then C_ChatInfo.RegisterAddonMessagePrefix(PREFIX) end

local Readable = FG.Readable

--- "id:f1,f2;id:f1" for the quests of the log ("x": the objective is finished). Read through
--- FG.QuestLog, as the rest of the addon: WoW Forever has C_QuestLog and no GetQuestLogTitle (the
--- global one sent an empty log there, so nobody saw anyone's progress).
function Party.Encode()
    local parts = {}
    for i = 1, (QuestLog.GetNumQuestLogEntries() or 0) do
        local info = QuestLog.GetInfo(i)
        local questID = info and not Readable(info.isHeader) and Readable(info.questID)
        if type(questID) == "number" and questID > 0 then
            local counts = {}
            for _, o in ipairs(QuestLog.GetQuestObjectives(questID) or {}) do
                local finished, have = Readable(o.finished), tonumber(Readable(o.numFulfilled)) or 0
                table.insert(counts, finished and "x" or tostring(have))
            end
            table.insert(parts, questID .. ":" .. table.concat(counts, ","))
        end
    end
    return parts
end
local Encode = Party.Encode

--- What we last sent, whole: the log is sent again only once it changed, or when asked.
local lastSent
--- Messages are 255 bytes at most: "R" starts a full update, then chunks, then "E:<chunks>"
--- ends it. `force`: also when nothing changed since the last one (asked for, a newcomer).
local function Send(force)
    if not FG:Get("partySync") or not IsInGroup() or IsInRaid() or not C_ChatInfo then return end
    local parts = Encode()
    local whole = table.concat(parts, ";")
    if not force and whole == lastSent then return end
    lastSent = whole
    local chunks, chunk = {}, ""
    for _, part in ipairs(parts) do
        if #chunk + #part + 1 > 240 then
            table.insert(chunks, chunk)
            chunk = ""
        end
        chunk = chunk == "" and part or (chunk .. ";" .. part)
    end
    if chunk ~= "" then table.insert(chunks, chunk) end
    C_ChatInfo.SendAddonMessage(PREFIX, "R", "PARTY")
    for _, c in ipairs(chunks) do
        C_ChatInfo.SendAddonMessage(PREFIX, c, "PARTY")
    end
    C_ChatInfo.SendAddonMessage(PREFIX, "E:" .. #chunks, "PARTY")
end

local scheduled, forced = false, false
local function SendSoon(force)
    forced = forced or force or false
    if scheduled or not C_Timer then return end
    scheduled = true
    C_Timer.After(2, function()
        local f = forced
        scheduled, forced = false, false
        Send(f)
    end)
end

--- Ask the party for their progress ("?": each member sends their log), and Questie players
--- for theirs: after a login or a reload, nothing would show until one of their counts moved.
--- At most every ASK_EVERY seconds: asked too soon, it is asked once that time has passed.
local ASK_EVERY = 10
local askedAt, askLater
function Party:Ask()
    if not FG:Get("partySync") or not IsInGroup() or IsInRaid() or not C_ChatInfo then return end
    local now = GetTime()
    if askedAt and now - askedAt < ASK_EVERY then
        if not askLater and C_Timer then
            askLater = true
            C_Timer.After(ASK_EVERY - (now - askedAt) + 0.1, function()
                askLater = false
                Party:Ask()
            end)
        end
        return
    end
    askedAt = now
    C_ChatInfo.SendAddonMessage(PREFIX, "?", "PARTY")
    if FG.QuestieShare and FG.QuestieShare.Ask then FG.QuestieShare:Ask() end
end

local function AskSoon()
    if not C_Timer then return Party:Ask() end
    C_Timer.After(3, function() Party:Ask() end)
end

--- The party members seen already: a member with no progress to show (no addon, an empty log)
--- is a newcomer once, not at each roster update.
local seen = {}

FG:On("QUEST_LOG_UPDATE", function() SendSoon() end)
FG:On("PLAYER_ENTERING_WORLD", AskSoon)
FG:On("GROUP_ROSTER_UPDATE", function()
    local newcomer, here = false, {}
    for i = 1, GetNumSubgroupMembers and GetNumSubgroupMembers() or 0 do
        local name = UnitName("party" .. i)
        if name then
            here[name] = true
            if not seen[name] then newcomer = true end
        end
    end
    seen = here
    for name in pairs(Party.progress) do
        if not here[name] and not UnitInParty(name) then
            Party.progress[name], Party.updates[name] = nil, nil
        end
    end
    -- A newcomer has nothing of ours yet: our log again, changed or not, and theirs asked for.
    if newcomer then
        SendSoon(true)
        AskSoon()
    end
end)

local function Refresh()
    if FG.Tracker then FG.Tracker:Refresh() end
    if FG.Nameplates then FG.Nameplates:Refresh() end
    if FG.Guide and FG.Guide.Refresh then FG.Guide:Refresh() end
end

--- Seconds after an "R" with no "E" (a member on a version that sends none) before the quests
--- it did not send again are dropped.
local SETTLE = 5

--- The quests of `name` missing from the update under way are gone from their log (handed in,
--- abandoned). Only when the update came whole (`complete`): a chunk lost on the way would take
--- its quests' lines away until their next change, so what was known is kept instead.
local function Finish(name, update, complete)
    if Party.updates[name] ~= update then return end
    Party.updates[name] = nil
    local mine = Party.progress[name]
    if not mine or not complete then return end
    local dropped = false
    for id in pairs(mine) do
        if not update.quests[id] then
            mine[id], dropped = nil, true
        end
    end
    if dropped then Refresh() end
end

FG:On("CHAT_MSG_ADDON", function(prefix, message, _, sender)
    if prefix ~= PREFIX then return end
    local name = Ambiguate(sender, "short")
    if name == UnitName("player") then return end
    -- Asked for our progress: our log, whole.
    if message == "?" then return SendSoon(true) end
    -- A full update starts: what is known stays shown until the new one has come in.
    if message == "R" then
        local update = { quests = {}, chunks = 0 }
        Party.updates[name] = update
        if C_Timer then C_Timer.After(SETTLE, function() Finish(name, update, not update.ended) end) end
        return
    end
    local update = Party.updates[name]
    local ended = message:match("^E:(%d+)$")
    if ended then
        if update then
            update.ended = true
            Finish(name, update, update.chunks == tonumber(ended))
        end
        return
    end
    local mine = Party.progress[name] or {}
    Party.progress[name] = mine
    if update then update.chunks = update.chunks + 1 end
    for id, counts in message:gmatch("(%d+):([^;]*)") do
        local list = {}
        for c in counts:gmatch("[^,]+") do
            table.insert(list, c)
        end
        mine[tonumber(id)] = list
        if update then update.quests[tonumber(id)] = true end
    end
    Refresh()
end)

--- Keep a party member's progress on a quest (from Questie: counts, "x" when finished).
function Party:Store(name, questID, counts)
    if not name or not questID then return end
    self.progress[name] = self.progress[name] or {}
    self.progress[name][questID] = counts
end

--- A party member no longer has the quest (handed in, abandoned).
function Party:Forget(name, questID)
    if self.progress[name] then self.progress[name][questID] = nil end
end

--- The party's progress on objective `objective` (its index in the log) of a quest, at most
--- 4 players, by name: { { name, have, need, done } }. `need`: the objective's count.
function Party:Members(questID, objective, need)
    if not FG:Get("partySync") then return {} end
    local out = {}
    for name, quests in pairs(self.progress) do
        local c = quests[questID] and quests[questID][objective]
        if c then
            local done = c == "x" or (need and tonumber(c) and tonumber(c) >= need) or false
            local have = c == "x" and need or tonumber(c) or 0
            out[#out + 1] = { name = name, have = have, need = need, done = done and true or false }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    while #out > 4 do
        table.remove(out)
    end
    return out
end

--- " (Name 3, Name ✓)" for an objective of a quest the party also has.
function Party:Suffix(questID, objective, required)
    if not FG:Get("partySync") then return "" end
    local parts = {}
    for name, quests in pairs(self.progress) do
        local c = quests[questID] and quests[questID][objective]
        if c then
            local done = c == "x" or (required and tonumber(c) and tonumber(c) >= required)
            table.insert(parts, name .. " " .. (done and "|TInterface\\RaidFrame\\ReadyCheck-Ready:10|t" or c))
        end
    end
    table.sort(parts)
    return #parts > 0 and ("  |cff9d9d9d(" .. table.concat(parts, ", ") .. ")|r") or ""
end
