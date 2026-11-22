-- Toolstrip: a floating bar of buttons for the current steps. First the trash can (Shift-click
-- destroys the cheapest grey item of the bags, right-click keeps that item: no longer offered),
-- a separator, then the quest item to use, a sword for each mob to kill (one press targets one
-- not tagged by another player, see Aiming; with "Mark the target with a skull", a skull on it too) and a speech bubble for the NPC to talk
-- to. Those five first buttons after the separator have key bindings (the game's key bindings,
-- "Pathwright" > "Toolstrip"); the trash can has none: a key press never destroys anything.
--
-- The buttons are secure: their actions, the strip's size and its place only change out of
-- combat; a change during a fight waits for its end. The trash can is not secure (it runs no
-- protected action), its look follows the bags at any time.

local FG = Pathwright
local T = FG.T
local Skin = FG.Skin

--- Buttons with a key binding (PWStrip1..PWStrip5), then unnamed ones up to MAX.
local BOUND = 5
local MAX = 10
local SIZE = 32
local GAP = 4
local GRIP = 10
--- Between the trash can and the other buttons.
local SEPARATOR = 2
--- Our icons (addon/tools/toolstrip_icons.py): a symbol on a clear background; an item has its own.
local MEDIA = "Interface\\AddOns\\Pathwright_Guide\\Media\\"
local ICONS = { kill = MEDIA .. "Kill", talk = MEDIA .. "Talk" }
local TRASH_ICON = MEDIA .. "Trash"
local DEFAULT_POINT = { "BOTTOM", "UIParent", "BOTTOM", 0, 170 }
--- Bags searched for grey items: the backpack and the four bags.
local BAGS = 4

local Toolstrip = { actions = {}, steps = {}, signature = nil, pending = false, item = nil }
FG.Toolstrip = Toolstrip

local strip, trash, separator

--- A button's action, nil when it has none.
local function ActionOf(b)
    local a = b.action
    return type(a) == "table" and a or nil
end
local buttons = {}
--- Buttons whose step got done during a fight (locked until it ends): button -> true.
local staleOf = setmetatable({}, { __mode = "k" })

--- Whether button `b` waits for the fight's end to leave (its step is done).
function Toolstrip.IsStale(b) return staleOf[b] == true end

-- The actions -----------------------------------------------------------------------------------

--- The world ping of a kind of button, as the client's /ping takes it: the number of its ping type
--- (the words only match on English clients), nil without a ping system (Classic Era, TBC).
local PING_TYPES = { kill = { "Attack", 0, "attack" }, talk = { "OnMyWay", 3, "onmyway" } }
function Toolstrip.PingType(kind)
    local t = PING_TYPES[kind]
    if not t or not SLASH_PING1 then return nil end
    local enum = Enum and Enum.PingSubjectType
    return enum and enum[t[1]] or t[2]
end

--- What a button does once its target is found (nothing more when none was): the skull on a mob
--- to kill, the world ping of its kind. The skull with /tm, cleared first: /tm 8 alone would take
--- it off a mob that has it already. WoW Forever has /tm (a macro's /run SetRaidTarget is
--- blocked there); Classic Era and TBC mark with /run, never over a marker already placed.
local function Found(lines, kind)
    local ping = FG:Get("targetPing") and Toolstrip.PingType(kind)
    local mark = kind == "kill" and FG:Get("targetMark")
    if not (ping or mark) then return end
    table.insert(lines, "/stopmacro [@target,noexists]")
    if mark and FG.Edition == "forever" then
        table.insert(lines, "/tm 0")
        table.insert(lines, "/tm 8")
    elseif mark then
        table.insert(
            lines,
            '/run if UnitExists("target") and not GetRaidTargetIndex("target") then SetRaidTarget("target",8) end'
        )
    end
    if ping then table.insert(lines, SLASH_PING1 .. " [@target] " .. ping) end
end

--- The kill macro: target the mob by its exact name, never a dead one; then the skull and the
--- Attack ping on it (each when asked).
function Toolstrip.KillMacro(name)
    local lines = { "/cleartarget", "/targetexact " .. name, "/cleartarget [dead]" }
    Found(lines, "kill")
    return table.concat(lines, "\n")
end

--- The talk macro: target the NPC; then the On My Way ping on it (when asked). The target is
--- cleared first: when the NPC is out of reach, /targetexact finds nothing and the target of
--- before (the last step's NPC) would get the ping. This way there is no target and no ping.
function Toolstrip.TalkMacro(name)
    local lines = { "/cleartarget", "/targetexact " .. name }
    Found(lines, "talk")
    return table.concat(lines, "\n")
end

-- Aiming -----------------------------------------------------------------------------------
-- Out of combat, a press of a sword button decides then and there (its PreClick, which runs just
-- before the button's macro and may still change it): it picks one mob of its name among the
-- nameplates shown, alive, hostile and not tagged by another player (no credit for us), the
-- current target first, then in interact range, then the closest to the middle of the screen,
-- and targets that very unit. When every one in sight is tagged, the press does nothing; when
-- none is in sight (or enemy nameplates are off), it targets by name. Either way the macro then
-- clicks the checker (a hidden secure button): its own PreClick runs once the target is taken
-- and looks at it. Not the mob asked for, dead, or tagged by someone else: the checker clears
-- the target at once. The sword's macro goes on with the skull and the ping, which stop when the
-- target is gone: so none ever goes on a wrong target. (The ping stays in the sword's own macro:
-- the game does not ping from a macro run by /click.) In combat nothing may change: at its start
-- every button goes back to its macro by name (skull and ping without the checks), the checker
-- to nothing.

--- Seconds between two aims while nothing else asks for one.
local AIM_EVERY = 0.25

local Readable = FG.Readable

--- A unit fact, nil when the game lacks the function or keeps the value secret.
local function Fact(f, ...)
    if not f then return nil end
    return Readable(f(...))
end

local CHECK = "PWStripCheck"

--- The checker's click, then what a found target gets (skull, ping), stopped by its own guard
--- when the checker cleared the target.
local function ThenChecked(lines, kind)
    table.insert(lines, "/click " .. CHECK)
    Found(lines, kind)
    return table.concat(lines, "\n")
end

--- Out of combat, a press aimed at a nameplate's unit: that very mob (alive and hostile, or
--- nothing), then the checker, then the skull and the ping.
function Toolstrip.AimedMacro(unit)
    return ThenChecked({ "/cleartarget", string.format("/target [@%s,exists,harm,nodead]", unit) }, "kill")
end

--- Out of combat, a press with no mob in sight: by name, then the checker, the skull and the ping.
function Toolstrip.CheckedMacro(a)
    if a.kind == "kill" then
        return ThenChecked({ "/cleartarget", "/targetexact " .. a.name, "/cleartarget [dead]" }, "kill")
    end
    return ThenChecked({ "/cleartarget", "/targetexact " .. a.name }, "talk")
end

--- What the checker does with the target taken: { name, kind, skipTapped } the press asked for.
function Toolstrip.CheckMacro(want)
    if not want or not Fact(UnitExists, "target") then return "" end
    local wrong = Fact(UnitName, "target") ~= want.name or Fact(UnitIsDead, "target")
    if want.kind == "kill" then
        wrong = wrong
            or (UnitCanAttack and not Fact(UnitCanAttack, "player", "target"))
            or (want.skipTapped and Fact(UnitIsTapDenied, "target"))
    end
    -- A right target: nothing to do here (the sword's macro marks and pings it).
    return wrong and "/cleartarget" or ""
end

--- How far a nameplate is from the middle of the screen (squared); a restricted one, or one the
--- game will not measure, counts as far.
local function ScreenDistance(plate)
    if not FG.PlateMeasurable(plate) then return math.huge end
    local ok, x, y = pcall(plate.GetCenter, plate)
    local cx, cy = UIParent:GetCenter()
    if not ok or not (x and cx) then return math.huge end
    local okScale, s = pcall(plate.GetEffectiveScale, plate)
    s = okScale and s or 1
    local u = UIParent:GetEffectiveScale() or 1
    return (x * s - cx * u) ^ 2 + (y * s - cy * u) ^ 2
end

--- The mob of this name to aim at among the nameplates shown: its unit, or nil and whether one
--- was seen tagged by someone else.
function Toolstrip.Pick(name)
    local best, bestScore, tapped
    local plates = C_NamePlate and C_NamePlate.GetNamePlates and C_NamePlate.GetNamePlates() or {}
    for _, plate in ipairs(plates) do
        local unit = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
        local hostile = not UnitCanAttack or Fact(UnitCanAttack, "player", unit)
        if unit and hostile and Fact(UnitName, unit) == name and not Fact(UnitIsDead, unit) then
            if Fact(UnitIsTapDenied, unit) then
                tapped = true
            else
                local score = ScreenDistance(plate)
                if Fact(UnitIsUnit, unit, "target") then
                    score = -2
                elseif Fact(CheckInteractDistance, unit, 4) then
                    score = -1 / (1 + score)
                end
                if not bestScore or score < bestScore then
                    best, bestScore = unit, score
                end
            end
        end
    end
    return best, tapped
end

--- Give button `b` this macro (out of combat), when it changed.
local function SetMacro(b, macro)
    if b.aimed ~= macro then
        b:SetAttribute("macrotext", macro)
        b.aimed = macro
    end
end

--- How a sword button stands: "aim" (a mob in sight to target), "tapped" (every one in sight is
--- tagged by someone else: dimmed, does nothing), "name" (none in sight).
local function SetState(b, state)
    b.state = state
    local stale = staleOf[b] == true
    b.icon:SetDesaturated(state == "tapped" or stale)
    b:SetAlpha(stale and 0.3 or state == "tapped" and 0.45 or 1)
    if b.done then b.done:SetShown(stale) end
end

--- A press of `b` out of combat: the macro for the mobs in sight right now (see Aiming).
function Toolstrip:Press(b)
    local a = ActionOf(b)
    if InCombatLockdown() or not a or (a.kind ~= "kill" and a.kind ~= "talk") then return end
    local skip = a.kind == "kill" and FG:Get("targetSkipTapped") and true or false
    self.expect = { name = a.name, kind = a.kind, skipTapped = skip }
    if not skip then
        SetMacro(b, Toolstrip.CheckedMacro(a))
        return
    end
    local unit, tapped = Toolstrip.Pick(a.name)
    if unit then
        SetMacro(b, Toolstrip.AimedMacro(unit))
        SetState(b, "aim")
    elseif tapped then
        SetMacro(b, "")
        SetState(b, "tapped")
    else
        SetMacro(b, Toolstrip.CheckedMacro(a))
        SetState(b, "name")
    end
end

--- The first quest item of these steps (quests in the log with a usable item): link, texture.
local function QuestItem(steps)
    if not FG:Get("questItemButton") or not GetQuestLogSpecialItemInfo or not GetQuestLogIndexByID then return end
    for _, step in ipairs(steps) do
        local index = step.q and GetQuestLogIndexByID(step.q)
        if index and index > 0 then
            local link, texture = GetQuestLogSpecialItemInfo(index)
            if link then return link, texture end
        end
    end
end

--- What the strip offers for these steps, in order: { kind = "item"|"kill"|"talk", name, link,
--- texture, macro }. A mob or NPC named twice is listed once.
function Toolstrip.Actions(steps)
    local list, seen = {}, {}
    local link, texture = QuestItem(steps)
    if link then
        table.insert(list, { kind = "item", link = link, texture = texture, name = FG.ItemInfo(link) or link })
    end
    local function add(kind, name)
        if not name or name == "" or seen[kind .. "\0" .. name] or #list >= MAX then return end
        seen[kind .. "\0" .. name] = true
        local macro = kind == "kill" and Toolstrip.KillMacro(name) or Toolstrip.TalkMacro(name)
        table.insert(list, { kind = kind, name = name, texture = ICONS[kind], macro = macro })
    end
    for _, step in ipairs(steps) do
        if step.mobs then
            for _, name in ipairs(step.mobs) do
                add("kill", name)
            end
        elseif step.e == "npc" then
            add("talk", step.n)
        end
    end
    return list
end

local function Signature(actions)
    local parts = { FG:Get("toolstrip") and "on" or "off", FG:Get("toolstripTrash") and "trash" or "" }
    for _, a in ipairs(actions) do
        table.insert(parts, a.kind .. ":" .. (a.link or a.macro or ""))
    end
    return table.concat(parts, "\n")
end

-- Grey items ------------------------------------------------------------------------------------

--- Items kept at the player's request (right-click), per character: itemID -> true.
local sessionKept = {}
local function Kept()
    local state = FG.Guide and FG.Guide:State()
    if not state then return sessionKept end
    if type(state.keptJunk) ~= "table" then state.keptJunk = {} end
    return state.keptJunk
end

--- The grey items of the bags not kept, cheapest stack first: { bag, slot, id, name, count, value }.
function Toolstrip.Junk()
    local list = {}
    if not (C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemInfo) then return list end
    local kept = Kept()
    for bag = 0, BAGS do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.quality == 0 and info.itemID and not kept[info.itemID] then
                local count = info.stackCount or 1
                local name, _, _, _, _, _, _, _, _, _, price = FG.ItemInfo(info.itemID)
                table.insert(list, {
                    bag = bag,
                    slot = slot,
                    id = info.itemID,
                    name = name or info.hyperlink or ("item:" .. info.itemID),
                    count = count,
                    value = (price or 0) * count,
                })
            end
        end
    end
    table.sort(list, function(a, b)
        if a.value ~= b.value then return a.value < b.value end
        if a.bag ~= b.bag then return a.bag < b.bag end
        return a.slot < b.slot
    end)
    return list
end

local function Money(copper)
    if copper <= 0 then return T("no value") end
    return GetCoinTextureString and GetCoinTextureString(copper) or tostring(copper)
end

--- Destroy the cheapest grey item (the trash can's Shift-click). Checks the slot still holds it.
function Toolstrip:Destroy()
    local junk = Toolstrip.Junk()[1]
    if not junk or not C_Container or not DeleteCursorItem then return end
    if CursorHasItem and CursorHasItem() then return end
    local info = C_Container.GetContainerItemInfo(junk.bag, junk.slot)
    if not info or info.itemID ~= junk.id then return end
    C_Container.PickupContainerItem(junk.bag, junk.slot)
    if CursorHasItem and not CursorHasItem() then return end
    DeleteCursorItem()
    FG:Print(T("destroyed: %dx %s"), junk.count, junk.name)
end

--- Keep the cheapest grey item (the trash can's right-click): no longer offered.
function Toolstrip:Keep()
    local junk = Toolstrip.Junk()[1]
    if not junk then return end
    Kept()[junk.id] = true
    FG:Print(T("kept: %s (no longer offered to the trash can)"), junk.name)
    self:RefreshTrash()
end

-- The frames ------------------------------------------------------------------------------------

local function Tooltip(self)
    local a = self.action
    if not a then return end
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    if a.kind == "item" and a.link then
        GameTooltip:SetHyperlink(a.link)
    else
        GameTooltip:SetText(string.format(a.kind == "kill" and T("Kill: %s") or T("Talk to: %s"), a.name))
    end
    if staleOf[self] then
        GameTooltip:AddLine(
            T("Done: this button leaves the toolstrip when the fight ends (the game locks it until then)"),
            0.3,
            0.9,
            0.5,
            true
        )
    elseif self.state == "aim" then
        GameTooltip:AddLine(T("Aimed at one in sight, not tagged by another player"), 0.6, 0.9, 0.6, true)
    elseif self.state == "tapped" then
        GameTooltip:AddLine(
            T("Every one in sight is tagged by another player: the button does nothing"),
            1,
            0.5,
            0.4,
            true
        )
    elseif self.state == "name" then
        GameTooltip:AddLine(T("None in sight: targets the nearest by name"), 0.6, 0.6, 0.6, true)
    end
    local key = self.binding and GetBindingKey and GetBindingKey(self.binding)
    if key then GameTooltip:AddLine(string.format(T("Key: %s"), key), 0.6, 0.6, 0.6) end
    GameTooltip:Show()
end

local function TrashTooltip(self)
    local junk = Toolstrip.Junk()
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    if not junk[1] then
        GameTooltip:SetText(T("No grey item to destroy"))
        GameTooltip:Show()
        return
    end
    local first = junk[1]
    GameTooltip:SetText(T("Shift-click to destroy:"))
    GameTooltip:AddDoubleLine(
        string.format("%dx %s", first.count, first.name),
        Money(first.value),
        0.62,
        0.62,
        0.62,
        1,
        1,
        1
    )
    GameTooltip:AddLine(T("Right-click to keep this item"), 0.6, 0.6, 0.6)
    if junk[2] then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(T("More grey items:"))
        for i = 2, math.min(#junk, 8) do
            local j = junk[i]
            GameTooltip:AddDoubleLine(
                string.format("%dx %s", j.count, j.name),
                Money(j.value),
                0.62,
                0.62,
                0.62,
                1,
                1,
                1
            )
        end
    end
    GameTooltip:Show()
end

local function Create()
    if strip or not CreateFrame then return strip end
    strip = CreateFrame("Frame", "PathwrightToolstrip", FG.UIRoot)
    strip:SetSize(GRIP + SIZE + 2 * GAP, SIZE + 2 * GAP)
    strip:SetClampedToScreen(true)
    FG:Draggable(strip, function(self)
        local p, _, rp, x, y = self:GetPoint()
        local state = FG.Guide and FG.Guide:State()
        if state then state.toolstripPoint = { p, "UIParent", rp, x, y } end
    end)
    Skin:Style(strip, "panel")
    strip:Hide()

    -- The checker (see Aiming): hidden, clicked by the swords' macros. Its macro runs on the up
    -- edge whatever the player's "cast on key down" (a /click is an up), and its PreClick looks
    -- at the target taken.
    local check = CreateFrame("Button", CHECK, strip, "SecureActionButtonTemplate")
    check:SetSize(1, 1)
    check:SetAttribute("type", "macro")
    check:SetAttribute("useOnKeyDown", false)
    check:SetAttribute("macrotext", "")
    check:RegisterForClicks("AnyUp")
    check:EnableMouse(false)
    check:SetScript("PreClick", function(self)
        if InCombatLockdown() then return end
        self.macro = Toolstrip.CheckMacro(Toolstrip.expect)
        self:SetAttribute("macrotext", self.macro)
        Toolstrip.expect = nil
    end)
    Toolstrip.checker = check

    separator = strip:CreateTexture(nil, "ARTWORK")
    separator:SetSize(SEPARATOR, SIZE - 6)
    separator:SetColorTexture(0.55, 0.55, 0.58, 0.8)
    separator:Hide()

    trash = CreateFrame("Button", "PathwrightTrash", strip)
    trash:SetSize(SIZE, SIZE)
    trash:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local icon = trash:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexture(TRASH_ICON)
    trash.icon = icon
    trash:SetScript("OnClick", function(self, mouse)
        if mouse == "RightButton" then
            Toolstrip:Keep()
        elseif IsShiftKeyDown() then
            Toolstrip:Destroy()
        end
        if GameTooltip:IsOwned(self) then TrashTooltip(self) end
    end)
    trash:SetScript("OnEnter", TrashTooltip)
    trash:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return strip
end

--- The secure button `i` (created out of combat): named and bound for the first five.
local function Button(i)
    if buttons[i] then return buttons[i] end
    local name = i <= BOUND and ("PWStrip" .. i) or nil
    local b = CreateFrame("Button", name, strip, "SecureActionButtonTemplate")
    b:SetSize(SIZE, SIZE)
    b:RegisterForClicks("AnyUp", "AnyDown")
    b.binding = name and ("CLICK " .. name .. ":LeftButton") or nil
    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    b.icon = icon
    -- Its step done during a fight (the button is locked until it ends): a check over it.
    b.done = b:CreateTexture(nil, "OVERLAY")
    b.done:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
    b.done:SetSize(SIZE * 0.6, SIZE * 0.6)
    b.done:SetPoint("CENTER")
    b.done:Hide()
    local cooldown = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
    cooldown:SetAllPoints()
    b.cooldown = cooldown
    b:SetScript("OnEnter", Tooltip)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetScript("PreClick", function(self) Toolstrip:Press(self) end)
    buttons[i] = b
    return b
end

--- Give button `b` its action (out of combat).
local function Arm(b, a)
    b.action = a
    staleOf[b] = nil
    if b.done then b.done:Hide() end
    if a.kind == "item" then
        b:SetAttribute("type", "item")
        b:SetAttribute("item", a.link)
        b:SetAttribute("macrotext", nil)
    else
        b:SetAttribute("type", "macro")
        b:SetAttribute("macrotext", a.macro)
        b:SetAttribute("item", nil)
    end
    b.aimed, b.state = a.macro, a.kind == "kill" and "name" or nil
    b.icon:SetDesaturated(false)
    b:SetAlpha(1)
    -- An item's own icon without the game's edge, like the others.
    if a.kind == "item" then
        b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    else
        b.icon:SetTexCoord(0, 1, 0, 1)
    end
    b.icon:SetTexture(a.texture)
    b:Show()
end

--- The trash can: dimmed when there is no grey item to offer.
function Toolstrip:RefreshTrash()
    if not trash then return end
    local has = Toolstrip.Junk()[1] ~= nil
    trash.icon:SetDesaturated(not has)
    trash:SetAlpha(has and 1 or 0.45)
end

--- Lay the strip out for `actions` (out of combat).
local function Apply(actions)
    if not Create() then return end
    local wanted = FG:Get("toolstrip") and (actions[1] ~= nil or FG:Get("toolstripTrash"))
    if not wanted then
        -- The buttons emptied too: their keys still click them when the strip is hidden.
        for _, b in ipairs(buttons) do
            b.action, staleOf[b] = nil, nil
            b:SetAttribute("type", nil)
            b:SetAttribute("macrotext", nil)
            b:Hide()
        end
        strip:Hide()
        return
    end
    -- The trash can first, a separator, then the buttons of the steps.
    local x = GRIP + GAP
    local withTrash = FG:Get("toolstripTrash") and true or false
    trash:SetShown(withTrash)
    if withTrash then
        trash:ClearAllPoints()
        trash:SetPoint("LEFT", strip, "LEFT", x, 0)
        x = x + SIZE + GAP
        Toolstrip:RefreshTrash()
    end
    local withSeparator = withTrash and actions[1] ~= nil
    separator:SetShown(withSeparator)
    if withSeparator then
        separator:ClearAllPoints()
        separator:SetPoint("LEFT", strip, "LEFT", x, 0)
        x = x + SEPARATOR + GAP
    end
    for i, a in ipairs(actions) do
        local b = Button(i)
        Arm(b, a)
        b:ClearAllPoints()
        b:SetPoint("LEFT", strip, "LEFT", x, 0)
        x = x + SIZE + GAP
    end
    for i = #actions + 1, #buttons do
        buttons[i].action = nil
        staleOf[buttons[i]] = nil
        buttons[i]:SetAttribute("type", nil)
        buttons[i]:SetAttribute("macrotext", nil)
        buttons[i]:Hide()
    end
    strip:SetWidth(x)
    strip:SetHeight(SIZE + 2 * GAP)
    local state = FG.Guide and FG.Guide:State()
    local point = state and state.toolstripPoint or DEFAULT_POINT
    strip:ClearAllPoints()
    strip:SetPoint(point[1], _G[point[2]] or UIParent, point[3], point[4], point[5])
    strip:Show()
    Toolstrip:Cooldowns()
    Toolstrip:Aim()
end

--- Follow these steps (the guide's steps to do, Guide.lua): now, or when combat ends.
function Toolstrip:SetSteps(steps)
    self.steps = steps or {}
    local actions = Toolstrip.Actions(self.steps)
    local signature = Signature(actions)
    if signature == self.signature and not self.pending then return end
    self.actions = actions
    self.item = actions[1] and actions[1].kind == "item" and actions[1].link or nil
    if InCombatLockdown() then
        -- The secure buttons and their keys are locked until the fight ends: a button whose step
        -- is done now is shown so (dimmed, checked), then leaves when the fight ends.
        self.pending = true
        local still = {}
        for _, a in ipairs(actions) do
            still[a.kind .. "\0" .. (a.link or a.macro or "")] = true
        end
        for _, b in ipairs(buttons) do
            local a = ActionOf(b)
            if a and b:IsShown() then
                staleOf[b] = not still[a.kind .. "\0" .. (a.link or a.macro or "")] or nil
                SetState(b, b.state)
            end
        end
        return
    end
    self.pending = false
    self.signature = signature
    Apply(actions)
end

--- Again with the same steps (a setting changed).
function Toolstrip:Refresh()
    self.signature = nil
    self:SetSteps(self.steps)
end

--- The quest item's cooldown on its button.
function Toolstrip:Cooldowns()
    if not GetItemCooldown then return end
    for _, b in ipairs(buttons) do
        local a = ActionOf(b)
        if a and a.kind == "item" and b:IsShown() then
            local id = tonumber(a.link:match("item:(%d+)"))
            local start, duration = GetItemCooldown(id)
            if start then b.cooldown:SetCooldown(start, duration) end
        end
    end
end

--- Show how every sword button stands with the mobs in sight (the press decides for itself).
function Toolstrip:Aim()
    if not strip or not strip:IsShown() then return end
    local on = FG:Get("targetSkipTapped")
    for _, b in ipairs(buttons) do
        local a = ActionOf(b)
        if a and a.kind == "kill" and b:IsShown() then
            local state = "name"
            if on and not InCombatLockdown() then
                local unit, tapped = Toolstrip.Pick(a.name)
                state = unit and "aim" or tapped and "tapped" or "name"
            end
            SetState(b, state)
            if GameTooltip:IsOwned(b) then Tooltip(b) end
        end
    end
end

--- Back to targeting by name (combat starts: the buttons are fixed until it ends).
function Toolstrip:Unaim()
    if InCombatLockdown() then return end
    for _, b in ipairs(buttons) do
        local a = ActionOf(b)
        if a and (a.kind == "kill" or a.kind == "talk") then SetMacro(b, a.macro) end
        if a and a.kind == "kill" then SetState(b, "name") end
    end
    if self.checker then
        self.checker.macro = ""
        self.checker:SetAttribute("macrotext", "")
    end
    self.expect = nil
end

-- Aimed again when the mobs in sight change, and every AIM_EVERY seconds (the camera turns).
local aimer = CreateFrame("Frame")
local sinceAim = 0
aimer:SetScript("OnUpdate", function(_, elapsed)
    sinceAim = sinceAim + (elapsed or 0)
    if sinceAim >= AIM_EVERY then
        sinceAim = 0
        Toolstrip:Aim()
    end
end)
for _, event in ipairs({ "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED", "PLAYER_TARGET_CHANGED" }) do
    FG:On(event, function() Toolstrip:Aim() end)
end
FG:On("UNIT_FLAGS", function(unit)
    if type(unit) == "string" and unit:find("^nameplate") then Toolstrip:Aim() end
end)
-- The game still lets protected frames change while this event runs, before the lockdown.
FG:On("PLAYER_REGEN_DISABLED", function() Toolstrip:Unaim() end)

FG:On("PLAYER_REGEN_ENABLED", function()
    if Toolstrip.pending then Toolstrip:SetSteps(Toolstrip.steps) end
    Toolstrip:Aim()
end)
FG:On("BAG_UPDATE_COOLDOWN", function() Toolstrip:Cooldowns() end)
FG:On("BAG_UPDATE_DELAYED", function()
    Toolstrip:RefreshTrash()
    if trash and GameTooltip:IsOwned(trash) then TrashTooltip(trash) end
end)
FG:On("PLAYER_LOGIN", function()
    for _, key in ipairs({
        "toolstrip",
        "toolstripTrash",
        "targetMark",
        "targetPing",
        "targetSkipTapped",
        "questItemButton",
    }) do
        FG:OnSetting(key, function() Toolstrip:Refresh() end)
    end
end)

--- "Toolstrip back to its place" (the addon's options): under the screen's centre again.
function Toolstrip:ResetPosition()
    local state = FG.Guide and FG.Guide:State()
    if state then state.toolstripPoint = nil end
    if InCombatLockdown() then
        FG:Print(T("not possible in combat"))
        return
    end
    self:Refresh()
end

FG.Options:AddButton("toolstripTrash", {
    label = "Toolstrip back to its place",
    text = "Reset",
    help = "Puts the toolstrip back above the action bars. Drag it by its left edge to move it.",
    run = function() Toolstrip:ResetPosition() end,
})
