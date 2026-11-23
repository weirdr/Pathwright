-- Quest progress on the nameplates of quest mobs: left of the plate, a sword (a mob to kill) or a
-- money bag (a mob that drops a quest item to loot) with the count of the first objective it
-- counts for that is not done ("3/10"). Show our count first, then a party member's count with
-- their name underneath, then a green check for our completed objectives.
--
-- What a mob counts for is read from the game's own structured unit tooltip
-- (C_TooltipInfo.GetUnit): a QuestTitle line gives the quest, each QuestObjective line its
-- objective with its counts. The objective's type (monster or item) comes from matching its text
-- with C_QuestLog.GetQuestObjectives. Every value read may be secret (instances on WoW Forever):
-- then nothing is shown. The mobs seen this session are remembered with their objectives, so the
-- check stays once the game stops listing a finished objective on the mob.

local FG = Pathwright
local QuestLog = FG.QuestLog
local Readable = FG.Readable

local MEDIA = "Interface\\AddOns\\Pathwright_Guide\\Media\\"
local ICONS = { kill = MEDIA .. "Kill", loot = MEDIA .. "Loot" }
local CHECK = "Interface\\RaidFrame\\ReadyCheck-Ready"
local SIZE = 16
--- Alpha of a mob tagged by another player.
local TAPPED_ALPHA = 0.35

local Nameplates = { marks = {}, pool = {} }
FG.Nameplates = Nameplates

-- The player's objectives -------------------------------------------------------------------

--- C_QuestLog.GetQuestObjectives(questID), readable entries only: { [index] = { text, type,
--- finished, have, need } }. Cached until the quest log changes.
local objectivesOf = {}
local function Objectives(questID)
    local list = objectivesOf[questID]
    if list then return list end
    list = {}
    local result = C_QuestLog and C_QuestLog.GetQuestObjectives and Readable(C_QuestLog.GetQuestObjectives(questID))
    if type(result) == "table" then
        for index, o in ipairs(result) do
            o = Readable(o)
            if type(o) == "table" then
                list[index] = {
                    text = Readable(o.text),
                    type = Readable(o.type),
                    finished = Readable(o.finished),
                    have = Readable(o.numFulfilled),
                    need = Readable(o.numRequired),
                }
            end
        end
    end
    objectivesOf[questID] = list
    return list
end

-- Members can have different counts in the same localized objective text.
local function ObjectiveText(text)
    if type(text) == "string" then
        return (text:gsub("%d+%s*/%s*%d+", "#/#"):gsub("%d+%s*%%", "#%%"):match("^%s*(.-)%s*$"))
    end
end

local function ObjectiveIndex(questID, text)
    text = ObjectiveText(text)
    if not text then return nil end
    local found
    for index, o in pairs(Objectives(questID)) do
        if ObjectiveText(o.text) == text then
            if found then return nil end
            found = index
        end
    end
    return found
end

--- Mobs seen this session (by name): the objectives they count for, { { quest, index } }.
local seen = {}

-- Resolve a QuestPlayer heading against the current roster. A private or unfamiliar heading
-- cannot identify a count. Keep it distinct from a tooltip with no heading.
local function TooltipOwner(line)
    local text = Readable(line.leftText)
    if type(text) ~= "string" then return false end
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):match("^%s*(.-)%s*:?%s*$")
    local raid = IsInRaid and IsInRaid()
    local count = raid and GetNumGroupMembers() or (GetNumSubgroupMembers and GetNumSubgroupMembers() or 0)
    for i = 0, count do
        local unit = i == 0 and "player" or (raid and "raid" or "party") .. i
        local name = Readable(UnitName(unit))
        if name and (text == name or (GetUnitName and text == Readable(GetUnitName(unit, true)))) then
            return i == 0 and true or text
        end
    end
    return false
end

local function ProgressCount(o, have, need, text, owner)
    local percent = type(text) == "string" and text:match("(%d+)%s*%%")
    return {
        kind = o and o.type == "item" and "loot" or "kill",
        have = have,
        need = need,
        percent = percent and tonumber(percent),
        owner = owner,
    }
end

function Nameplates.Progress(unit)
    local name = Readable(UnitName(unit))
    local lines
    if C_TooltipInfo and C_TooltipInfo.GetUnit and Enum and Enum.TooltipDataLineType then
        local info = Readable(C_TooltipInfo.GetUnit(unit))
        lines = info and Readable(info.lines)
    end
    local LT = Enum and Enum.TooltipDataLineType
    local known = {}
    local grouped = IsInGroup and IsInGroup()
    local questID, owner, ownerHeading, mine, party, done
    for _, line in ipairs(type(lines) == "table" and lines or {}) do
        local kind = Readable(line.type)
        if kind == LT.QuestTitle then
            questID = Readable(line.id)
            if not ownerHeading then owner = nil end
            ownerHeading = false
        elseif LT.QuestPlayer and kind == LT.QuestPlayer then
            owner = TooltipOwner(line)
            ownerHeading = true
        elseif kind == LT.QuestObjective and questID then
            ownerHeading = false
            local finished = Readable(line.completed)
            if finished ~= nil then
                local text = Readable(line.leftText)
                local index = ObjectiveIndex(questID, text)
                local o = index and Objectives(questID)[index]
                if QuestLog.IsOnQuest(questID) then
                    if index then table.insert(known, { quest = questID, index = index }) end
                    if owner == true or (owner == nil and not grouped) then
                        if finished then
                            done = true
                        elseif not mine then
                            mine = ProgressCount(o, Readable(line.numFulfilled), Readable(line.numRequired), text)
                        end
                    end
                end
                if type(owner) == "string" and not finished and not party then
                    party = ProgressCount(o, Readable(line.numFulfilled), Readable(line.numRequired), text, owner)
                end
            end
        end
    end
    if name and known[1] then seen[name] = known end
    if mine then return mine end
    -- The log identifies our count even when the tooltip only lists another member. It also
    -- remembers completion when the tooltip drops an objective after our last kill.
    local before = name and seen[name] or known
    local allDone, any = true, false
    for _, k in ipairs(before) do
        if QuestLog.IsOnQuest(k.quest) then
            local o = Objectives(k.quest)[k.index]
            any = true
            allDone = allDone and o ~= nil and o.finished == true
            if o and o.finished == false and grouped then return ProgressCount(o, o.have, o.need, o.text) end
            if o and o.finished then
                if grouped and not party and FG.Party and o.need then
                    for _, member in ipairs(FG.Party:Members(k.quest, k.index, o.need)) do
                        if not member.done and UnitInParty(member.name) then
                            party = ProgressCount(o, member.have, member.need, nil, member.name)
                            break
                        end
                    end
                end
            end
        end
    end
    if party then return party end
    if done or (any and allDone) then return { done = true } end
end

--- The count shown: "3/10", "40%" for an objective in percent.
function Nameplates.Count(p)
    if p.percent then return p.percent .. "%" end
    if p.have and p.need then return p.have .. "/" .. p.need end
    return ""
end

-- The marks ---------------------------------------------------------------------------------

local function Mark()
    local f = table.remove(Nameplates.pool)
    if f then return f end
    f = CreateFrame("Frame")
    f:SetSize(SIZE, SIZE)
    f:EnableMouse(false)
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(SIZE, SIZE)
    f.count = f:CreateFontString(nil, "OVERLAY")
    f.count:SetFontObject(FG.Skin.FontObject(11, "OUTLINE", true))
    f.owner = f:CreateFontString(nil, "OVERLAY")
    f.owner:SetFontObject(FG.Skin.FontObject(9, "OUTLINE", true))
    f.owner:SetPoint("TOPRIGHT", f.count, "BOTTOMRIGHT", 0, -1)
    return f
end

local function Release(unit)
    local f = Nameplates.marks[unit]
    if not f then return end
    Nameplates.marks[unit] = nil
    f:Hide()
    f:ClearAllPoints()
    f:SetParent(nil)
    table.insert(Nameplates.pool, f)
end

--- Draw (or take off) the mark of a nameplate unit.
function Nameplates:Update(unit)
    if not FG:Get("questNameplates") then return Release(unit) end
    local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit and C_NamePlate.GetNamePlateForUnit(unit)
    -- A restricted nameplate (instances, some friendly ones) takes no frame of ours.
    if not FG.PlateUsable(plate) then plate = nil end
    local p = plate and Nameplates.Progress(unit)
    if not p then return Release(unit) end
    local f = self.marks[unit] or Mark()
    self.marks[unit] = f
    f:SetParent(plate)
    f:SetFrameStrata("HIGH")
    f:ClearAllPoints()
    f:SetPoint("RIGHT", plate, "LEFT", -2, 0)
    f.icon:ClearAllPoints()
    f.count:ClearAllPoints()
    f.owner:SetText(p.owner or "")
    f.owner:SetShown(p.owner ~= nil)
    if p.done then
        -- Only the check, the height of the count.
        f.icon:SetTexture(CHECK)
        f.icon:SetDesaturated(false)
        f.icon:SetPoint("RIGHT", f, "RIGHT", 0, 0)
        f.count:SetText("")
        f.count:Hide()
        f:SetWidth(SIZE)
    else
        f.icon:SetTexture(ICONS[p.kind])
        f.count:SetText(Nameplates.Count(p))
        f.count:Show()
        f.count:SetPoint("RIGHT", f, "RIGHT", 0, 0)
        f.icon:SetPoint("RIGHT", f.count, "LEFT", -2, 0)
        f:SetWidth(SIZE + 2 + (tonumber(f.count:GetStringWidth()) or 24))
    end
    -- Tagged by someone else: no credit for us.
    local tapped = not p.done
        and FG:Get("questNameplatesTapped")
        and UnitIsTapDenied
        and Readable(UnitIsTapDenied(unit))
        and true
    f:SetAlpha(tapped and TAPPED_ALPHA or 1)
    f.icon:SetDesaturated(tapped and true or false)
    f.tapped = tapped
    f.progress = p
    f:Show()
end

--- Every nameplate shown again (the quest log or a setting changed): on the next frame, once.
local pending = false
function Nameplates:Refresh()
    if pending then return end
    pending = true
    local function Run()
        pending = false
        objectivesOf = {}
        for _, plate in ipairs(C_NamePlate and C_NamePlate.GetNamePlates and C_NamePlate.GetNamePlates() or {}) do
            local unit = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
            if unit then self:Update(unit) end
        end
        for unit in pairs(self.marks) do
            if not (UnitExists(unit) and C_NamePlate.GetNamePlateForUnit(unit)) then Release(unit) end
        end
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(0, Run)
    else
        Run()
    end
end

FG:On("NAME_PLATE_UNIT_ADDED", function(unit) Nameplates:Update(unit) end)
FG:On("NAME_PLATE_UNIT_REMOVED", function(unit) Release(unit) end)
for _, event in ipairs({ "QUEST_LOG_UPDATE", "UNIT_QUEST_LOG_CHANGED", "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD" }) do
    FG:On(event, function() Nameplates:Refresh() end)
end
-- A mob tagged (or let go) by someone: its flags change.
FG:On("UNIT_FLAGS", function(unit)
    if type(unit) == "string" and unit:find("^nameplate") then Nameplates:Update(unit) end
end)
FG:On("PLAYER_LOGIN", function()
    for _, key in ipairs({ "questNameplates", "questNameplatesTapped", "partySync" }) do
        FG:OnSetting(key, function() Nameplates:Refresh() end)
    end
end)
