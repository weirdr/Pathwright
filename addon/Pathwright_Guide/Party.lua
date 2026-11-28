-- Group sync: members running Pathwright send their quest progress (objectives fulfilled) to
-- the party, on its own: Questie is not needed. Questie players' progress comes in too, through
-- QuestieShare.lua (which also answers them). The tracker shows theirs next to each objective,
-- the guide a line under each objective step (Party:Members).
--
-- The members also tell each other that they run the addon ("!", asked with "!?"), whatever the
-- progress setting: a quest taken in a party is shared with it at once (Party:Share), by
-- default only when every member runs the addon.

local FG = Pathwright
local QuestLog = FG.QuestLog

local PREFIX = "PWSYNC1"
local Party = { progress = {}, pending = {}, askedFor = {}, token = 0 }
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

--- The party's progress changed: the guide shows it, and moves on from an objective that waited
--- for a member (the "partyWait" setting).
local function GuideChanged()
    local guide = FG.Guide
    if not guide then return end
    if FG:Get("partyWait") and guide.Advance then return guide:Advance() end
    if guide.Refresh then guide:Refresh() end
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
--- At most every ASK_EVERY seconds. Returns true when the request went out, or one did within
--- the last ASK_EVERY seconds (false when nothing can be sent: sync off, no party, a raid).
local ASK_EVERY = 10
local askedAt
function Party:Ask()
    if not FG:Get("partySync") or not IsInGroup() or IsInRaid() or not C_ChatInfo then return false end
    local now = GetTime()
    if askedAt and now - askedAt < ASK_EVERY then return true end
    askedAt = now
    C_ChatInfo.SendAddonMessage(PREFIX, "?", "PARTY")
    if FG.QuestieShare and FG.QuestieShare.Ask then FG.QuestieShare:Ask() end
    return true
end

--- Ask because a quest has no member data: once per quest until the roster changes.
function Party:AskFor(questID)
    if self.askedFor[questID] then return end
    -- Flagged only once a request is out (or pending in the throttle window).
    if self:Ask() then self.askedFor[questID] = true end
end

local function AskSoon()
    if not C_Timer then return Party:Ask() end
    C_Timer.After(3, function() Party:Ask() end)
end

FG:On("QUEST_LOG_UPDATE", SendSoon)
FG:On("PLAYER_ENTERING_WORLD", AskSoon)
FG:On("GROUP_ROSTER_UPDATE", function()
    Party.askedFor = {}
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
    -- A member who left holds the guide no more.
    if FG:Get("partyWait") then GuideChanged() end
end)

FG:On("CHAT_MSG_ADDON", function(prefix, message, _, sender)
    if prefix ~= PREFIX then return end
    local name = Ambiguate(sender, "short")
    if Party.Own(name) then return end
    if Party:Heard(name, message) then return end
    -- Asked for our progress: our log, whole.
    if message == "?" then return SendSoon() end
    if message == "R" then
        -- A full update starts: what we have stays shown until its first chunk replaces it
        -- (an empty log sends no chunk: the old data goes after a few seconds).
        Party.token = Party.token + 1
        local token = Party.token
        Party.pending[name] = token
        if C_Timer then
            C_Timer.After(5, function()
                if Party.pending[name] == token then
                    Party.pending[name] = nil
                    Party.progress[name] = {}
                    if FG.Tracker then FG.Tracker:Refresh() end
                    if FG.Nameplates then FG.Nameplates:Refresh() end
                    GuideChanged()
                end
            end)
        end
        return
    end
    if Party.pending[name] then
        Party.pending[name] = nil
        Party.progress[name] = {}
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
    GuideChanged()
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
    if not FG:Get("partySync") or (IsInRaid and IsInRaid()) then return {} end
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

--- Names of the party members running the addon who have the quest and have not finished its
--- objective `objective` (its index in the log; nil: any of its objectives), `need` being the
--- objective's count: the guide waits for them on an objective we finished (the "partyWait"
--- setting). A member who is offline holds nobody, nor one who has not the quest (not taken yet,
--- or handed in), nor one heard through Questie only.
function Party:Behind(questID, objective, need)
    local out = {}
    if not FG:Get("partyWait") or not FG:Get("partySync") then return out end
    if not IsInGroup() or IsInRaid() then return out end
    for name, quests in pairs(self.progress) do
        local counts = quests[questID]
        if counts and self:Uses(name) and not (UnitIsConnected and UnitIsConnected(name) == false) then
            local behind = false
            if objective then
                local c = counts[objective]
                behind = c ~= nil and c ~= "x" and not (need and tonumber(c) and tonumber(c) >= need)
            else
                for _, c in ipairs(counts) do
                    if c ~= "x" then behind = true end
                end
            end
            if behind then out[#out + 1] = name end
        end
    end
    table.sort(out)
    return out
end

--- " (Name 3, Name ✓)" for an objective of a quest the party also has.
function Party:Suffix(questID, objective, required)
    if not FG:Get("partySync") or (IsInRaid and IsInRaid()) then return "" end
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

-- Who runs the addon, and quests shared on taking them -----------------------------------------

-- A quest is shared this long after it is taken (seconds): the members who took it at the same
-- quest giver have said so by then.
local SHARE_AFTER = 1.5
-- A quest a member shared with us is not shared back for this long.
local OFFERED = 300
-- "Who runs the addon?" is asked at most this often.
local HELLO_EVERY = 5

Party.users = {} -- who was heard running the addon, by name (Names)
local taken = {} -- name -> { [questID] = true }: the quests a member said it took
local offered = {} -- questID -> GetTime() a member shared it at
local waiting = {} -- questID -> true: taken in a fight, shared after it

--- A player's name without its realm, as one word and its first word alone: on WoW Forever a
--- character's own game names it by its first word and the others by its whole name, so two
--- names are the same player when either of the two matches.
local function Names(name)
    local short = tostring(name or ""):gsub("%-.*", "")
    return (short:gsub("%s", "")), short:match("^(%S+)") or ""
end

--- Whether a sender's name is ours: our own messages come back to us, on WoW Forever under our
--- whole name, which our own game does not give.
function Party.Own(name)
    local bare, first = Names(name)
    local own = Names(UnitName("player"))
    return own ~= "" and (bare == own or first == own)
end

--- The other members of the party, by name.
local function Members()
    local names = {}
    for i = 1, GetNumSubgroupMembers and GetNumSubgroupMembers() or 0 do
        local name = Readable(UnitName("party" .. i))
        if type(name) == "string" and name ~= "" then names[#names + 1] = name end
    end
    return names
end

local function Tell(message)
    if not C_ChatInfo or not C_ChatInfo.SendAddonMessage or not IsInGroup() or IsInRaid() then return end
    C_ChatInfo.SendAddonMessage(PREFIX, message, "PARTY")
end

--- A message of ours came from `name`: it runs the addon. Returns true when the message was
--- about that or about a quest taken or shared, and not the member's progress.
function Party:Heard(name, message)
    local bare, first = Names(name)
    if bare ~= "" then
        self.users[bare], self.users[first] = true, true
    end
    if message == "!" then return true end
    if message == "!?" then
        self:Hello()
        return true
    end
    local kind, id = message:match("^([AP]):(%d+)$")
    if not kind then return false end
    id = tonumber(id)
    if kind == "P" then offered[id] = GetTime() end
    -- Who shares a quest has it, as who took it.
    for _, key in ipairs({ bare, first }) do
        taken[key] = taken[key] or {}
        taken[key][id] = true
    end
    return true
end

--- Whether a party member was heard running the addon.
function Party:Uses(name)
    local bare, first = Names(name)
    return (self.users[bare] or self.users[first]) and true or false
end

--- Whether every other member of the party runs the addon (false alone).
function Party:Everyone()
    local members = Members()
    for _, name in ipairs(members) do
        if not self:Uses(name) then return false end
    end
    return #members > 0
end

local helloSoon = false
--- Say that we run the addon, once for everyone who asked in the last second.
function Party:Hello()
    if helloSoon then return end
    if not C_Timer then return Tell("!") end
    helloSoon = true
    C_Timer.After(1, function()
        helloSoon = false
        Tell("!")
    end)
end

local askedUsersAt
--- Ask who runs the addon (the question says that we do), when a member is not known to.
local function AskUsers()
    if not IsInGroup() or IsInRaid() or Party:Everyone() then return end
    local now = GetTime()
    if askedUsersAt and now - askedUsersAt < HELLO_EVERY then return end
    askedUsersAt = now
    Tell("!?")
end

--- Whether a member has the quest: it said it took it, or its progress holds it.
local function Has(name, questID)
    local bare, first = Names(name)
    if (taken[bare] and taken[bare][questID]) or (taken[first] and taken[first][questID]) then return true end
    for other, quests in pairs(Party.progress) do
        if quests[questID] then
            local b, f = Names(other)
            if b == bare or f == first then return true end
        end
    end
    return false
end

--- The quest's place in the log when the game lets it be shared, nil otherwise.
local function Shareable(questID)
    local index = QuestLog.GetLogIndexForQuestID(questID)
    if type(index) ~= "number" or index < 1 or not QuestLogPushQuest then return nil end
    if C_QuestLog and C_QuestLog.IsPushableQuest then
        local ok, yes = pcall(C_QuestLog.IsPushableQuest, questID)
        return ok and Readable(yes) and index or nil
    end
    -- Classic Era and TBC answer for the quest selected in the log.
    if not SelectQuestLogEntry or not GetQuestLogPushable then return nil end
    local was = GetQuestLogSelection and GetQuestLogSelection()
    SelectQuestLogEntry(index)
    local yes = GetQuestLogPushable()
    if was and was ~= index then SelectQuestLogEntry(was) end
    return yes and index or nil
end

--- Share the quest at `index` of the log: the game shares the quest selected in the log, which
--- is selected for that and the log's own selection put back.
local function Push(questID, index)
    if C_QuestLog and C_QuestLog.SetSelectedQuest then
        local was = C_QuestLog.GetSelectedQuest and C_QuestLog.GetSelectedQuest()
        pcall(C_QuestLog.SetSelectedQuest, questID)
        local ok = pcall(QuestLogPushQuest, index)
        if type(was) == "number" and was ~= questID then pcall(C_QuestLog.SetSelectedQuest, was) end
        return ok
    end
    local was = GetQuestLogSelection and GetQuestLogSelection()
    SelectQuestLogEntry(index)
    local ok = pcall(QuestLogPushQuest)
    if was and was ~= index then SelectQuestLogEntry(was) end
    return ok
end

--- Share a quest of the log with the party. Returns true when it was shared; otherwise false
--- and why not: "off" (the setting), "alone" (no party, or a raid), "members" (one does not run
--- the addon and the setting asks for all), "offered" (a member just shared it with us),
--- "have" (every member has it), "combat" (shared after the fight), "unshareable" (the game
--- does not let this quest be shared, or it left the log).
function Party:Share(questID)
    if not FG:Get("questShare") then return false, "off" end
    local members = IsInGroup() and not IsInRaid() and Members() or {}
    if #members == 0 then return false, "alone" end
    if FG:Get("questShareAll") and not self:Everyone() then return false, "members" end
    if offered[questID] and GetTime() - offered[questID] < OFFERED then return false, "offered" end
    local missing = false
    for _, name in ipairs(members) do
        if not Has(name, questID) then missing = true end
    end
    if not missing then return false, "have" end
    if InCombatLockdown and InCombatLockdown() then
        waiting[questID] = true
        return false, "combat"
    end
    local index = Shareable(questID)
    if not index then return false, "unshareable" end
    -- Said before the quest is offered: who takes it from us does not share it back.
    Tell("P:" .. questID)
    if not Push(questID, index) then return false, "unshareable" end
    return true
end

local function ShareNow(questID)
    local shared, why = Party:Share(questID)
    FG:Debug("quest %d %s", questID, shared and "shared with the party" or ("not shared: " .. tostring(why)))
end

--- Who in the party runs the addon, and what sharing would do: `/pw party`.
function Party:Say()
    local members = Members()
    if #members == 0 or IsInRaid() then return FG:Print(FG.T("party: you are not in a party")) end
    for _, name in ipairs(members) do
        if self:Uses(name) then
            FG:Print(FG.T("party: %s runs Pathwright"), name)
        else
            FG:Print(FG.T("party: %s was not heard running Pathwright"), name)
        end
    end
    if not FG:Get("questShare") then
        FG:Print(FG.T("party: sharing the quests you take is turned off (Options, Party and Sync)"))
    elseif FG:Get("questShareAll") and not self:Everyone() then
        FG:Print(FG.T("party: quests are not shared until every member runs Pathwright"))
    else
        FG:Print(FG.T("party: the quests you take are shared"))
    end
end

-- Classic Era and TBC pass (questLogIndex, questID), Forever only (questID).
FG:On("QUEST_ACCEPTED", function(arg1, arg2)
    local questID = tonumber(Readable(arg2) or Readable(arg1))
    if not questID or not IsInGroup() or IsInRaid() then return end
    -- Told at once, whatever our settings: a member who shares its quests need not offer us this one.
    Tell("A:" .. questID)
    if not FG:Get("questShare") then return end
    if not C_Timer then return ShareNow(questID) end
    C_Timer.After(SHARE_AFTER, function() ShareNow(questID) end)
end)

FG:On("PLAYER_REGEN_ENABLED", function()
    for questID in pairs(waiting) do
        waiting[questID] = nil
        ShareNow(questID)
    end
end)

FG:On("GROUP_ROSTER_UPDATE", function()
    if not IsInGroup() then
        Party.users, taken, offered, waiting = {}, {}, {}, {}
        return
    end
    AskUsers()
end)

FG:On("PLAYER_ENTERING_WORLD", function()
    if not C_Timer then return AskUsers() end
    C_Timer.After(3, AskUsers)
end)
