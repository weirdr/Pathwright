-- Quest progress on the nameplates of quest mobs: left of the plate, a sword (a mob to kill) or a
-- money bag (a mob that drops a quest item to loot) with the count of the first objective it
-- counts for that is not done ("3/10"), then a green check once every objective it counts for is
-- done. Mobs tagged by another player (no credit for us) are dimmed, when asked.
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

--- The index of the objective of `questID` whose text is `text` (the tooltip line's), nil when
--- none or several match.
local function ObjectiveIndex(questID, text)
    if not text then return nil end
    local found
    for index, o in pairs(Objectives(questID)) do
        if o.text == text then
            if found then return nil end
            found = index
        end
    end
    return found
end

--- Mobs seen this session (by name): the objectives they count for, { { quest, index } }.
local seen = {}

--- What a unit counts for among the player's quests: { kind = "kill"|"loot", have, need } of the
--- first objective not done, { done = true } when all are, nil when none (or unreadable).
function Nameplates.Progress(unit)
    local name = Readable(UnitName(unit))
    local lines
    if C_TooltipInfo and C_TooltipInfo.GetUnit and Enum and Enum.TooltipDataLineType then
        local info = Readable(C_TooltipInfo.GetUnit(unit))
        lines = info and Readable(info.lines)
    end
    local LT = Enum and Enum.TooltipDataLineType
    local questID, found, first, known = nil, false, nil, {}
    for _, line in ipairs(type(lines) == "table" and lines or {}) do
        local kind = Readable(line.type)
        if kind == LT.QuestTitle then
            questID = Readable(line.id)
        elseif kind == LT.QuestObjective and questID and QuestLog.IsOnQuest(questID) then
            local done = Readable(line.completed)
            if done ~= nil then
                found = true
                local text = Readable(line.leftText)
                local index = ObjectiveIndex(questID, text)
                if index then table.insert(known, { quest = questID, index = index }) end
                if done == false and not first then
                    local o = index and Objectives(questID)[index]
                    local percent = type(text) == "string" and text:match("(%d+)%s*%%")
                    first = {
                        kind = o and o.type == "item" and "loot" or "kill",
                        have = Readable(line.numFulfilled),
                        need = Readable(line.numRequired),
                        percent = percent and tonumber(percent),
                    }
                end
            end
        end
    end
    if name and known[1] then seen[name] = known end
    if first then return first end
    if found then return { done = true } end
    -- Not listed (any more): done if the objectives seen on it are, while their quests are on.
    local before = name and seen[name]
    if not before then return nil end
    local allDone, any = true, false
    for _, k in ipairs(before) do
        if QuestLog.IsOnQuest(k.quest) then
            any = true
            local o = Objectives(k.quest)[k.index]
            allDone = allDone and o ~= nil and o.finished == true
        end
    end
    if any and allDone then return { done = true } end
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
for _, event in ipairs({ "QUEST_LOG_UPDATE", "UNIT_QUEST_LOG_CHANGED", "PLAYER_ENTERING_WORLD" }) do
    FG:On(event, function() Nameplates:Refresh() end)
end
-- A mob tagged (or let go) by someone: its flags change.
FG:On("UNIT_FLAGS", function(unit)
    if type(unit) == "string" and unit:find("^nameplate") then Nameplates:Update(unit) end
end)
FG:On("PLAYER_LOGIN", function()
    for _, key in ipairs({ "questNameplates", "questNameplatesTapped" }) do
        FG:OnSetting(key, function() Nameplates:Refresh() end)
    end
end)
