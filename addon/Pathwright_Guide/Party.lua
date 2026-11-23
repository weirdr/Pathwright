-- Group sync: members running Pathwright send their quest progress (objectives fulfilled) to
-- the party, on its own: Questie is not needed. Questie players' progress comes in too, through
-- QuestieShare.lua (which also answers them). The tracker shows theirs next to each objective,
-- the guide a line under each objective step (Party:Members).

local FG = Pathwright
local QuestLog = FG.QuestLog

local PREFIX = "PWSYNC1"
local Party = { progress = {} }
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

local function Send()
    if not FG:Get("partySync") or not IsInGroup() or IsInRaid() or not C_ChatInfo then return end
    -- Messages are 255 bytes at most: "R" starts a full update, then chunks.
    C_ChatInfo.SendAddonMessage(PREFIX, "R", "PARTY")
    local chunk = ""
    for _, part in ipairs(Encode()) do
        if #chunk + #part + 1 > 240 then
            C_ChatInfo.SendAddonMessage(PREFIX, chunk, "PARTY")
            chunk = ""
        end
        chunk = chunk == "" and part or (chunk .. ";" .. part)
    end
    if chunk ~= "" then C_ChatInfo.SendAddonMessage(PREFIX, chunk, "PARTY") end
end

local scheduled = false
local function SendSoon()
    if scheduled or not C_Timer then return end
    scheduled = true
    C_Timer.After(2, function()
        scheduled = false
        Send()
    end)
end

--- Ask the party for their progress ("?": each member sends their log), and Questie players
--- for theirs: after a login or a reload, nothing would show until one of their counts moved.
--- At most every ASK_EVERY seconds.
local ASK_EVERY = 10
local askedAt
function Party:Ask()
    if not FG:Get("partySync") or not IsInGroup() or IsInRaid() or not C_ChatInfo then return end
    local now = GetTime()
    if askedAt and now - askedAt < ASK_EVERY then return end
    askedAt = now
    C_ChatInfo.SendAddonMessage(PREFIX, "?", "PARTY")
    if FG.QuestieShare and FG.QuestieShare.Ask then FG.QuestieShare:Ask() end
end

local function AskSoon()
    if not C_Timer then return Party:Ask() end
    C_Timer.After(3, function() Party:Ask() end)
end

FG:On("QUEST_LOG_UPDATE", SendSoon)
FG:On("PLAYER_ENTERING_WORLD", AskSoon)
FG:On("GROUP_ROSTER_UPDATE", function()
    local newcomer = false
    for name in pairs(Party.progress) do
        if not UnitInParty(name) then Party.progress[name] = nil end
    end
    for i = 1, GetNumSubgroupMembers and GetNumSubgroupMembers() or 0 do
        local name = UnitName("party" .. i)
        if name and not Party.progress[name] then newcomer = true end
    end
    SendSoon()
    if newcomer then AskSoon() end
end)

FG:On("CHAT_MSG_ADDON", function(prefix, message, _, sender)
    if prefix ~= PREFIX then return end
    local name = Ambiguate(sender, "short")
    if name == UnitName("player") then return end
    -- Asked for our progress: our log, whole.
    if message == "?" then return SendSoon() end
    if message == "R" then
        Party.progress[name] = {}
        if FG.Nameplates then FG.Nameplates:Refresh() end
        return
    end
    local mine = Party.progress[name] or {}
    Party.progress[name] = mine
    for id, counts in message:gmatch("(%d+):([^;]*)") do
        local list = {}
        for c in counts:gmatch("[^,]+") do
            table.insert(list, c)
        end
        mine[tonumber(id)] = list
    end
    if FG.Tracker then FG.Tracker:Refresh() end
    if FG.Nameplates then FG.Nameplates:Refresh() end
    if FG.Guide and FG.Guide.Refresh then FG.Guide:Refresh() end
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
