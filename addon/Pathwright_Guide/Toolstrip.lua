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
--
-- The step buttons can show in the guide's card too (see "In the guide window"): beside the step
-- each belongs to, in a row under the card's header, or both.

local FG = Pathwright
local T = FG.T
local Skin = FG.Skin

--- Buttons with a key binding (PWStrip1..PWStrip5), then unnamed ones up to MAX.
local BOUND = 5
local MAX = 10
--- The icons' size and the names' length (characters) unless the settings say otherwise, and
--- what the settings may ask for.
local SIZE, MIN_SIZE, MAX_SIZE = 24, 12, 48
local NAME_LENGTH, MAX_NAME = 24, 40
--- The size of the names' letters (and of the counts after them), likewise.
local FONT, MIN_FONT, MAX_FONT = 10, 8, 20
local RESTED_SIZE = 16
--- The height a name takes under or beside its icon, and the most room one takes under an icon
--- (in a row: the game cuts a longer one with dots, so a row of many buttons stays short).
--- (Both for letters of the usual size, FONT: larger letters take as much more.)
local CAPTION_HEIGHT = 12
local MAX_LABEL_WIDTH = 62
local BUTTON_HEIGHT = SIZE + CAPTION_HEIGHT
local GAP = 4
--- Between a name and the count after it.
local COUNT_GAP = 3
local GRIP = 10
--- Between the trash can and the other buttons.
local SEPARATOR = 2
--- Our icons (addon/tools/toolstrip_icons.py): a symbol on a clear background; an item has its own.
local MEDIA = "Interface\\AddOns\\Pathwright_Guide\\Media\\"
local ICONS = { kill = MEDIA .. "Kill", talk = MEDIA .. "Talk" }
local TRASH_ICON = MEDIA .. "Trash"
local BOOSTED_RESTED = 1229451
local DEFAULT_POINT = { "BOTTOM", "UIParent", "BOTTOM", 0, 170 }
--- Bags searched for grey items: the backpack and the four bags.
local BAGS = 4

local Toolstrip = { actions = {}, steps = {}, signature = nil, pending = false, item = nil }
FG.Toolstrip = Toolstrip

local strip, trash, rested, separator

--- A button's action, nil when it has none.
local function ActionOf(b)
    local a = b.action
    return type(a) == "table" and a or nil
end
local buttons = {}
--- The same actions on buttons inside the guide's card (see "In the guide window").
local docked = {}
--- Every secure step button: the strip's, then the card's.
local function Each(fn)
    for _, b in ipairs(buttons) do
        fn(b)
    end
    for _, b in ipairs(docked) do
        fn(b)
    end
end
--- The count shown after a button's name: button -> { text = "3/10", width, named }.
local countOf = setmetatable({}, { __mode = "k" })
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
-- Out of combat, a press of a sword button decides then and there (its PreClick, before its
-- macro runs), from the target and the nameplates shown (see Plan). WoW Forever targets no
-- nameplate unit from a macro and the game takes the nearest of a name, so:
--   * The current target is a mob of that name fit to kill (alive, not tagged by someone else):
--     kept, the skull and the ping on it. So a fit mob clicked by hand gets them.
--   * The nearest of that name is fit: by name, the skull and the ping (then the checker, a hidden
--     secure button that clears a wrong target where the game runs it from a macro).
--   * The nearest is tagged by someone else: by name and one Tab (/targetenemy) to the next enemy.
--   * The skull and the ping only go on when the mob the press ends on is for sure a fit one of
--     that name: the ranges are coarse, mobs as near may be taken in either order.
-- The button always does something: never dimmed. In combat nothing may change: at its start
-- every button goes back to its macro by name (skull and ping without the checks), the checker to
-- nothing.

--- Seconds between two aims while nothing else asks for one.
local AIM_EVERY = 0.25

local Readable = FG.Readable

--- A unit fact, nil when the game lacks the function, refuses it (an error: WoW Forever guards
--- some of them for nameplate units) or keeps the value secret.
local function Fact(f, ...)
    if not f then return nil end
    local ok, v = pcall(f, ...)
    if not ok then return nil end
    return Readable(v)
end

local CHECK = "PWStripCheck"

--- The checker's click, then what a found target gets (skull, ping), stopped by its own guard
--- when the checker cleared the target.
local function ThenChecked(lines, kind)
    table.insert(lines, "/click " .. CHECK)
    Found(lines, kind)
    return table.concat(lines, "\n")
end

--- Out of combat, a press: by name, then the checker, the skull and the ping.
function Toolstrip.CheckedMacro(a)
    if a.kind == "kill" then
        return ThenChecked({ "/cleartarget", "/targetexact " .. a.name, "/cleartarget [dead]" }, "kill")
    end
    return ThenChecked({ "/cleartarget", "/targetexact " .. a.name }, "talk")
end

--- What the checker does with the target taken: { name, kind, skipTapped } the press asked for.
function Toolstrip.CheckMacro(want)
    if not want then return "" end
    local wrong = not Fact(UnitExists, "target")
        or Fact(UnitName, "target") ~= want.name
        or Fact(UnitIsDead, "target")
    if want.kind == "kill" then
        wrong = wrong
            or (UnitCanAttack and not Fact(UnitCanAttack, "player", "target"))
            or (want.skipTapped and Fact(UnitIsTapDenied, "target"))
    end
    -- A right target: nothing to do here (the sword's macro marks and pings it). A wrong one is
    -- cleared (WoW Forever targets no nameplate unit from a macro: no other one can be taken
    -- instead), and the sword's macro stops before the skull and the ping.
    if not wrong then return "" end
    return Fact(UnitExists, "target") and "/cleartarget" or ""
end

-- How far a mob is: the game tells an addon no distance to a hostile unit, only whether it is
-- within some ranges. Out of combat it answers for the interaction distances (about 10 and 28
-- yards) and for the player's own harmful spells (their range from the spellbook): the
-- shortest of these the mob is within is how far it is taken to be.

--- The ranges a mob can be checked against, shortest first: { yards, interact = index } or
--- { yards, spell = name }. Made again when the spellbook changes.
local ranges

local function Ranges()
    if ranges then return ranges end
    ranges = { { 10, interact = 3 }, { 28, interact = 4 } }
    local book = BOOKTYPE_SPELL or "spell"
    local seen = { [10] = true, [28] = true }
    if GetNumSpellTabs and GetSpellTabInfo and GetSpellBookItemName and IsHarmfulSpell and GetSpellInfo then
        for tab = 1, GetNumSpellTabs() or 0 do
            local _, _, offset, count = GetSpellTabInfo(tab)
            for i = (offset or 0) + 1, (offset or 0) + (count or 0) do
                local name = GetSpellBookItemName(i, book)
                local ok, harmful = pcall(IsHarmfulSpell, i, book)
                if name and ok and harmful then
                    local yards = tonumber((select(6, GetSpellInfo(name))))
                    if yards and yards > 0 and not seen[yards] then
                        seen[yards] = true
                        table.insert(ranges, { yards, spell = name })
                    end
                end
            end
        end
    end
    table.sort(ranges, function(a, b) return a[1] < b[1] end)
    return ranges
end
FG:On("SPELLS_CHANGED", function() ranges = nil end)

--- How many yards away a mob is at most (math.huge: beyond every range the game answers for).
function Toolstrip.Range(unit)
    for _, r in ipairs(Ranges()) do
        local within
        if r.interact then
            within = Fact(CheckInteractDistance, unit, r.interact)
        elseif IsSpellInRange then
            local ok, answer = pcall(IsSpellInRange, r.spell, unit)
            within = ok and (answer == 1 or answer == true)
        end
        if within then return r[1] end
    end
    return math.huge
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
--- was seen tagged by someone else (passed over when `skipTapped`). `notTarget`: not the current
--- target (the checker looks for another).
function Toolstrip.Pick(name, skipTapped, notTarget)
    local best, bestRange, bestScreen, tapped
    local plates = C_NamePlate and C_NamePlate.GetNamePlates and C_NamePlate.GetNamePlates() or {}
    for _, plate in ipairs(plates) do
        local unit = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
        local hostile = not UnitCanAttack or Fact(UnitCanAttack, "player", unit)
        local isTarget = unit and Fact(UnitIsUnit, unit, "target")
        if unit and hostile and Fact(UnitName, unit) == name and not Fact(UnitIsDead, unit) and not (notTarget and isTarget) then
            if skipTapped and Fact(UnitIsTapDenied, unit) then
                tapped = true
            else
                local range, screen = -1, 0
                if not isTarget then
                    range, screen = Toolstrip.Range(unit), ScreenDistance(plate)
                end
                if not bestRange or range < bestRange or (range == bestRange and screen < bestScreen) then
                    best, bestRange, bestScreen = unit, range, screen
                end
            end
        end
    end
    return best, tapped
end

--- How a press would go, from the nameplates shown (the game takes the nearest of a name; on WoW
--- Forever a macro can target nothing else but the next enemy, by Tab). Returns "name" or "tab"
--- (the nearest of `name` is tagged by someone else: one Tab more, to the next enemy), and whether
--- the mob it ends on is for sure one of `name` fit to kill (then the skull and the ping go on
--- it). The ranges are coarse (see Range): mobs at the same range may be taken in either order.
--- None of `name` in sight: by name, taken as fit (as ever).
function Toolstrip.Plan(name, skipTapped)
    local enemies = {}
    local plates = C_NamePlate and C_NamePlate.GetNamePlates and C_NamePlate.GetNamePlates() or {}
    for _, plate in ipairs(plates) do
        local unit = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
        local hostile = not UnitCanAttack or Fact(UnitCanAttack, "player", unit)
        if unit and hostile and not Fact(UnitIsDead, unit) then
            local mine = Fact(UnitName, unit) == name
            local tapped = Fact(UnitIsTapDenied, unit) and true or false
            table.insert(enemies, {
                unit = unit,
                fit = mine and not (skipTapped and tapped),
                mine = mine,
                range = Toolstrip.Range(unit),
            })
        end
    end
    -- The one taken by name: the nearest of `name`.
    local first
    for _, e in ipairs(enemies) do
        if e.mine and (not first or e.range < first.range) then first = e end
    end
    if not first then return "name", true end
    -- Another of `name` at the same range, not as fit: either may be taken.
    local tie = false
    for _, e in ipairs(enemies) do
        if e ~= first and e.mine and e.range == first.range and e.fit ~= first.fit then tie = true end
    end
    if first.fit then return "name", not tie end
    if tie then return "name", false end
    -- One Tab more: the nearest enemy after it, for sure only when no other is as near.
    local next, sure = nil, true
    for _, e in ipairs(enemies) do
        if e ~= first then
            if not next or e.range < next.range then
                next, sure = e, true
            elseif e.range == next.range then
                sure = false
            end
        end
    end
    return "tab", next ~= nil and next.fit and sure
end

--- The current target is a mob of this name fit to kill (alive, hostile, not tagged by someone
--- else when `skipTapped`).
local function TargetFit(name, skipTapped)
    return Fact(UnitExists, "target")
        and Fact(UnitName, "target") == name
        and not Fact(UnitIsDead, "target")
        and (not UnitCanAttack or Fact(UnitCanAttack, "player", "target"))
        and not (skipTapped and Fact(UnitIsTapDenied, "target"))
end

--- A press when the nearest of the name is tagged: by name, one Tab more to the next enemy, then
--- the skull and the ping only when `sure` it is a fit one.
function Toolstrip.TabMacro(name, sure)
    local lines = { "/cleartarget", "/targetexact " .. name, "/targetenemy", "/cleartarget [dead]" }
    if sure then Found(lines, "kill") end
    return table.concat(lines, "\n")
end

--- By name, the skull and the ping only when `sure` (no checker: it would take a tagged one off).
function Toolstrip.NameMacro(name, sure)
    local lines = { "/cleartarget", "/targetexact " .. name, "/cleartarget [dead]" }
    if sure then Found(lines, "kill") end
    return table.concat(lines, "\n")
end

--- A press on a target already fit: kept, the skull and the ping on it.
function Toolstrip.KeepMacro()
    local lines = {}
    Found(lines, "kill")
    return table.concat(lines, "\n")
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

--- A press of `b` out of combat: the macro for the mobs in sight right now (see Aiming). An error
--- on the way (a unit function the game refuses) leaves it by name with the checker, never the
--- plain macro of combat (no checks).
function Toolstrip:Press(b)
    local ok = pcall(self.Aimed, self, b)
    if not ok and not InCombatLockdown() then
        local a = ActionOf(b)
        if a and (a.kind == "kill" or a.kind == "talk") then
            local skip = a.kind == "kill" and FG:Get("targetSkipTapped") and true or false
            self.expect = { name = a.name, kind = a.kind, skipTapped = skip }
            SetMacro(b, Toolstrip.CheckedMacro(a))
        end
    end
end

function Toolstrip:Aimed(b)
    local a = ActionOf(b)
    if InCombatLockdown() or not a or (a.kind ~= "kill" and a.kind ~= "talk") then return end
    local skip = a.kind == "kill" and FG:Get("targetSkipTapped") and true or false
    self.expect = { name = a.name, kind = a.kind, skipTapped = skip }
    -- Decided before the macro runs (WoW Forever runs no /click of the checker from it, nor
    -- targets a nameplate unit): a target already fit is kept, with the skull and the ping; when
    -- the game, by name, could take a mob tagged by someone else, nothing at all (no target, no
    -- skull, no ping).
    if a.kind == "kill" then
        if TargetFit(a.name, skip) then
            SetMacro(b, Toolstrip.KeepMacro())
            return
        end
        local how, sure = Toolstrip.Plan(a.name, skip)
        if how == "tab" then
            SetMacro(b, Toolstrip.TabMacro(a.name, sure))
            return
        elseif not sure then
            SetMacro(b, Toolstrip.NameMacro(a.name, false))
            return
        end
    end
    SetMacro(b, Toolstrip.CheckedMacro(a))
end

--- The first quest item of these steps (quests in the log with a usable item): link, texture.
--- Whether an item can be used (it has a spell of its own): a letter to hand over has none.
local function Usable(item)
    local spell = (C_Item and C_Item.GetItemSpell) or GetItemSpell
    if not spell then return true end
    local ok, name = pcall(spell, item)
    return ok and name ~= nil
end

--- A quest's line in the log (nil when it is not there). The newer clients have no
--- GetQuestLogIndexByID: asked through the addon's own quest log.
local function LogIndex(questID)
    local find = FG.QuestLog and FG.QuestLog.GetLogIndexForQuestID
    local ok, index = pcall(find or function() end, questID)
    index = ok and tonumber(FG.Readable(index)) or nil
    return index and index > 0 and index or nil
end

--- The quest item to use for these steps: its link (or "item:<id>"), texture and name.
---   The item the game itself names for the quest (the one its own tracker shows), when it does.
---   Else the item the quest hands out when taken (QuestItems.lua, from the game data), when
---   the character carries it and it can be used: the game names an item for some quests only.
local function QuestItem(steps)
    if not FG:Get("questItemButton") then return end
    local asked = {}
    for _, step in ipairs(steps) do
        local index = step.q and not asked[step.q] and LogIndex(step.q)
        if index then
            asked[step.q] = true
            if GetQuestLogSpecialItemInfo then
                local link, texture = GetQuestLogSpecialItemInfo(index)
                if link then return link, texture, nil, step end
            end
            local id = FG.QuestItems and FG.QuestItems[step.q]
            if id and (tonumber(FG.ItemCount(id)) or 0) > 0 and Usable(id) then
                local ok, name, link, _, _, _, _, _, _, _, texture = pcall(FG.ItemInfo, id)
                if not ok then
                    name, link, texture = nil, nil, nil
                end
                texture = texture or (GetItemIcon and GetItemIcon(id)) or nil
                return type(link) == "string" and link or ("item:" .. id), texture, name, step
            end
        end
    end
end

--- What the strip offers for these steps, in order: { kind = "item"|"kill"|"talk", name, link,
--- texture, macro, step }. A mob or NPC named twice is listed once, with the first step that
--- names it (its objective's count goes after the name, see Count).
function Toolstrip.Actions(steps)
    local list, seen = {}, {}
    local link, texture, known, itemStep = QuestItem(steps)
    if link then
        local name = known or FG.ItemInfo(link) or link:match("%[(.-)%]") or ITEM or "Item"
        table.insert(list, { kind = "item", link = link, texture = texture, name = name, step = itemStep })
    end
    local function add(kind, name, step)
        if not name or name == "" or seen[kind .. "\0" .. name] or #list >= MAX then return end
        seen[kind .. "\0" .. name] = true
        local macro = kind == "kill" and Toolstrip.KillMacro(name) or Toolstrip.TalkMacro(name)
        table.insert(list, { kind = kind, name = name, texture = ICONS[kind], macro = macro, step = step })
    end
    for _, step in ipairs(steps) do
        if step.mobs then
            for _, name in ipairs(step.mobs) do
                add("kill", name, step)
            end
        elseif step.e == "npc" then
            add("talk", step.n, step)
        end
    end
    return list
end

--- How far an action's objective is, as the quest log has it now: "3/10". Nil when its step has
--- no counted objective (a talk, a turn-in), or when the setting is off.
function Toolstrip.Count(a)
    local step = a and a.step
    local count = FG.Guide and FG.Guide.Count
    if type(step) ~= "table" or not count or not FG:Get("toolstripProgress") then return nil end
    local ok, have, need = pcall(count, step)
    if not ok or not have or not need then return nil end
    return string.format("%d/%d", have, need)
end

--- A key as it fits on an icon: the modifiers as one letter ("SHIFT-F" -> "s-F"), the long names
--- short ("BUTTON4" -> "M4", "NUMPAD7" -> "N7", "MOUSEWHEELUP" -> "WU").
local MODIFIERS = { ALT = "a-", CTRL = "c-", SHIFT = "s-", META = "m-" }
local KEYS = {
    SPACE = "Spc",
    ESCAPE = "Esc",
    BACKSPACE = "Bksp",
    DELETE = "Del",
    INSERT = "Ins",
    PAGEUP = "PgUp",
    PAGEDOWN = "PgDn",
    HOME = "Home",
    END = "End",
    ENTER = "Ent",
    TAB = "Tab",
    CAPSLOCK = "Caps",
    NUMLOCK = "NumL",
    PRINTSCREEN = "Prt",
    UP = "Up",
    DOWN = "Dn",
    LEFT = "Lt",
    RIGHT = "Rt",
    MOUSEWHEELUP = "WU",
    MOUSEWHEELDOWN = "WD",
    NUMPADPLUS = "N+",
    NUMPADMINUS = "N-",
    NUMPADMULTIPLY = "N*",
    NUMPADDIVIDE = "N/",
    NUMPADDECIMAL = "N.",
}
function Toolstrip.KeyText(key)
    if type(key) ~= "string" then return "" end
    local modifiers, rest = "", key
    -- The modifiers come first, each with its dash; the key itself may be a dash ("CTRL--").
    while true do
        local modifier, after = rest:match("^(%u+)%-(.+)$")
        local short = modifier and MODIFIERS[modifier:gsub("^[LR]", "")] or MODIFIERS[modifier or ""]
        if not short then break end
        modifiers, rest = modifiers .. short, after
    end
    rest = KEYS[rest] or (rest:gsub("^NUMPAD(%d)$", "N%1"):gsub("^BUTTON(%d+)$", "M%1"))
    return modifiers .. rest
end

local function Signature(actions)
    local L = Toolstrip.Layout()
    local parts = {
        FG:Get("toolstrip") and "on" or "off",
        FG:Get("toolstripTrash") and "trash" or "",
        (L.list and "list" or "row") .. (L.right and ":right:" or ":left:") .. L.size .. ":" .. L.limit,
        "font:" .. L.font .. ":" .. tostring(FG:Get("uiFont")),
        (FG:Get("toolstripKeys") and "keys" or "") .. (FG:Get("toolstripProgress") and ":counts" or ""),
    }
    for _, a in ipairs(actions) do
        -- With the objective counted after its name: the same mob for another quest is another button.
        local step = type(a.step) == "table" and a.step.k == "objective" and a.step or nil
        local counted = step and (tostring(step.q) .. ":" .. tostring(step.n)) or ""
        table.insert(parts, a.kind .. ":" .. (a.link or a.macro or "") .. "\0" .. a.name .. "\0" .. counted)
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
    local formatCoins = C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString or GetCoinTextureString
    return formatCoins and formatCoins(copper) or tostring(copper)
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

--- How the strip is laid out, from its settings:
---   list   one button a line, its name in full beside its icon (else: side by side, a short
---          name under each icon);
---   right  the icons at the strip's right edge, the names running to their left, and the
---          strip held by its right corner (else: all of that from the left);
---   size   of the icons, in pixels; limit: the characters kept of a name (0: no names);
---   font   the size of the names' letters and of the counts after them.
local function Layout()
    local size = tonumber(FG:Get("toolstripIcon")) or SIZE
    local limit = tonumber(FG:Get("toolstripNameLength")) or NAME_LENGTH
    local font = tonumber(FG:Get("toolstripFont")) or FONT
    return {
        font = math.max(MIN_FONT, math.min(MAX_FONT, math.floor(font + 0.5))),
        list = FG:Get("toolstripLayout") == "list",
        right = FG:Get("toolstripSide") == "right",
        size = math.max(MIN_SIZE, math.min(MAX_SIZE, math.floor(size + 0.5))),
        limit = math.max(0, math.min(MAX_NAME, math.floor(limit + 0.5))),
    }
end
Toolstrip.Layout = Layout

--- A name cut to `limit` characters (never inside one), three dots where it was cut.
function Toolstrip.Limited(text, limit)
    if limit <= 0 then return "" end
    local count, i = 0, 1
    while i <= #text do
        local byte = text:byte(i)
        count = count + 1
        if count > limit then return (text:sub(1, i - 1):gsub("%s+$", "")) .. "..." end
        i = i + (byte >= 240 and 4 or byte >= 224 and 3 or byte >= 192 and 2 or 1)
    end
    return text
end

local function AddButtonArt(b)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(SIZE, SIZE)
    b.icon:SetPoint("TOP")
    b.caption = Skin:Text(b, 10, "text")
    b.caption:SetPoint("TOP", b.icon, "BOTTOM", 0, -1)
    b.caption:SetJustifyH("CENTER")
    -- Its objective's count, after the name: a text of its own, so that it moves on during a
    -- fight (a text may change then, a secure button's size may not).
    b.count = Skin:Text(b, 10, "text2")
    b.count:Hide()
end

--- The size of the key's letters for icons of this size: 8 on the smallest, 11 on the largest.
local function KeyFont(size) return Skin.FontObject(math.floor(size / 10) + 7, "OUTLINE", true) end

--- Give a button its look for the layout `L`: its icon's size, and its name under the icon (a
--- row) or beside it, on the side away from the strip's edge (a list); after the name, the
--- `count` of its objective ("3/10": in brackets after a name, bare without one). Returns its
--- width and height: the whole of it is the button, name included.
local function Dress(b, text, L, count)
    text = Toolstrip.Limited(text or "", L.limit)
    local named = text ~= ""
    local counted = type(count) == "string" and count ~= ""
    b.icon:SetSize(L.size, L.size)
    b.icon:ClearAllPoints()
    -- The letters' size, and with it the room a line of them takes.
    Skin:Resize(b.caption, L.font)
    Skin:Resize(b.count, L.font)
    local lineHeight = L.font + (CAPTION_HEIGHT - FONT)
    b.caption:ClearAllPoints()
    b.caption:SetWidth(0)
    b.caption:SetText(text)
    b.caption:SetShown(named)
    b.count:ClearAllPoints()
    b.count:SetText(counted and (named and "(" .. count .. ")" or count) or "")
    b.count:SetShown(counted)
    local textWidth = named and math.ceil(tonumber(b.caption:GetStringWidth()) or 0) + 2 or 0
    local countWidth = counted and math.ceil(tonumber(b.count:GetStringWidth()) or 0) + 2 or 0
    countOf[b] = counted and { text = count, width = countWidth, named = named } or nil
    -- In a row a long name is cut by the game (see MAX_LABEL_WIDTH), never its count.
    if not L.list then textWidth = math.min(math.floor(MAX_LABEL_WIDTH * L.font / FONT), textWidth) end
    local line = textWidth + (named and counted and COUNT_GAP or 0) + countWidth
    local lettered = named or counted
    local width, height
    if L.list then
        if L.right then
            -- From the icon leftward: the count, then the name ending at it.
            b.icon:SetPoint("RIGHT")
            b.count:SetPoint("RIGHT", b.icon, "LEFT", -GAP, 0)
            if counted then
                b.caption:SetPoint("RIGHT", b.count, "LEFT", -COUNT_GAP, 0)
            else
                b.caption:SetPoint("RIGHT", b.icon, "LEFT", -GAP, 0)
            end
            b.caption:SetJustifyH("RIGHT")
        else
            b.icon:SetPoint("LEFT")
            b.caption:SetPoint("LEFT", b.icon, "RIGHT", GAP, 0)
            if named then
                b.count:SetPoint("LEFT", b.caption, "RIGHT", COUNT_GAP, 0)
            else
                b.count:SetPoint("LEFT", b.icon, "RIGHT", GAP, 0)
            end
            b.caption:SetJustifyH("LEFT")
        end
        width = L.size + (lettered and GAP + line or 0)
        height = math.max(L.size, lettered and lineHeight or 0)
    else
        b.icon:SetPoint("TOP")
        width = math.max(L.size, line)
        height = L.size + (lettered and lineHeight or 0)
        if named and counted then
            -- The name and its count, the two of them centred under the icon.
            b.caption:SetPoint("TOPLEFT", b, "TOPLEFT", math.floor((width - line) / 2), -(L.size + 1))
            b.caption:SetJustifyH("LEFT")
            b.count:SetPoint("LEFT", b.caption, "RIGHT", COUNT_GAP, 0)
        else
            b.caption:SetPoint("TOP", b.icon, "BOTTOM", 0, -1)
            b.caption:SetJustifyH("CENTER")
            b.count:SetPoint("TOP", b.icon, "BOTTOM", 0, -1)
        end
    end
    if named then b.caption:SetWidth(textWidth) end
    b:SetSize(width, height)
    -- The check over a step done during a fight and the key's letters (the secure buttons have
    -- them, the trash can none).
    local done = rawget(b, "done")
    if done then done:SetSize(L.size * 0.6, L.size * 0.6) end
    local key = rawget(b, "key")
    -- (Never the UI suite's font: it would take the outline that keeps a key readable on an icon.)
    if key then key:SetFontObject(KeyFont(L.size)) end
    return width, height
end

local function RestedAvailable()
    if not (GetXPExhaustion and UnitXPMax) then return false end
    -- An empty rested pool is normally nil. A secret value is unknown.
    local xp = GetXPExhaustion()
    local levelXP = UnitXPMax("player")
    if issecretvalue and (issecretvalue(xp) or issecretvalue(levelXP)) then return false end
    if xp == nil then xp = 0 end
    -- Anything but a finite, non-negative pool and a finite, positive maximum is unknown.
    if type(xp) ~= "number" or type(levelXP) ~= "number" then return false end
    if not (xp >= 0 and xp < math.huge and levelXP > 0 and levelXP < math.huge) then return false end
    return xp < levelXP * 0.005
        and FG.HasPlayerAura(BOOSTED_RESTED) == false
end

local function RefreshRested()
    if not rested then return end
    local available = RestedAvailable()
    if available == rested:IsShown() then return end
    rested:SetShown(available)
    if InCombatLockdown() then
        Toolstrip.pending = true
    else
        Toolstrip:Refresh()
    end
end

--- Prefer the last distinctive word: Highland Strider / Highland Thrasher become Strider / Thrasher.
local function ShortNames(actions)
    local counts, labels = {}, {}
    for _, a in ipairs(actions) do
        for word in a.name:gmatch("%S+") do
            counts[word] = (counts[word] or 0) + 1
        end
    end
    for i, a in ipairs(actions) do
        local label = a.name
        for word in a.name:gmatch("%S+") do
            if counts[word] == 1 then label = word end
        end
        labels[i] = label
    end
    return labels
end

--- Build the strip, each of its parts that is missing: one that could not be made before (a
--- fight: the game makes no secure button then; an error) is made the next time, so a strip half
--- built never stays so (no trash can, no bar).
local function Create()
    if not CreateFrame then return strip end
    if not strip then
        strip = CreateFrame("Frame", "PathwrightToolstrip", FG.UIRoot, "BackdropTemplate")
        strip:SetSize(GRIP + SIZE + 2 * GAP, BUTTON_HEIGHT + 2 * GAP)
        strip:SetClampedToScreen(true)
        FG:Draggable(strip, function(self)
            local state = FG.Guide:State()
            if state then state.toolstripPoint = FG.PinTopLeft(self) or state.toolstripPoint end
        end, function(self)
            if FG:Get("toolstripUnlocked") then return self end
        end)
        strip:Hide()
    end
    if not strip.styled then
        strip.styled = true
        FG:Try("toolstrip skin", Skin.Style, Skin, strip, "panel")
    end

    -- The checker (see Aiming): hidden, clicked by the swords' macros, and its PreClick looks at
    -- the target taken. A /click comes as a down or an up depending on the player's "cast on key
    -- down" (on WoW Forever, a down when it is on), and a secure button acts only on the edge its
    -- useOnKeyDown names: the PreClick sets it to the edge of this very click, or the checker would
    -- decide and then do nothing. A secure button: made out of combat only.
    if not Toolstrip.checker and not InCombatLockdown() then
        local check = CreateFrame("Button", CHECK, strip, "SecureActionButtonTemplate")
        if check then
            check:SetSize(1, 1)
            check:SetAttribute("type", "macro")
            check:SetAttribute("useOnKeyDown", false)
            check:SetAttribute("macrotext", "")
            check:RegisterForClicks("AnyUp", "AnyDown")
            check:EnableMouse(false)
            check:SetScript("PreClick", function(self, _, down)
                if InCombatLockdown() then return end
                self:SetAttribute("useOnKeyDown", down and true or false)
                self.macro = Toolstrip.CheckMacro(Toolstrip.expect)
                self:SetAttribute("macrotext", self.macro)
                Toolstrip.expect = nil
            end)
            Toolstrip.checker = check
        end
    end

    if not separator then
        separator = strip:CreateTexture(nil, "ARTWORK")
        separator:SetSize(SEPARATOR, BUTTON_HEIGHT - 6)
        separator:SetColorTexture(0.55, 0.55, 0.58, 0.8)
        separator:Hide()
    end

    if not trash then
        trash = CreateFrame("Button", "PathwrightTrash", strip)
        trash:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        AddButtonArt(trash)
        trash.icon:SetTexture(TRASH_ICON)
        trash.columnWidth = Dress(trash, BAG_FILTER_JUNK or "Junk", Layout())
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
    end
    if FG.Edition == "forever" and not rested then
        rested = CreateFrame("Frame", "PathwrightRestedXP", strip)
        rested:SetSize(RESTED_SIZE, RESTED_SIZE)
        rested.icon = rested:CreateTexture(nil, "ARTWORK")
        rested.icon:SetAllPoints()
        local icon = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(BOOSTED_RESTED)
        rested.icon:SetTexture(icon or "Interface\\Icons\\Spell_Nature_Sleep")
        rested.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        rested.glow = rested:CreateTexture(nil, "OVERLAY")
        rested.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        rested.glow:SetBlendMode("ADD")
        rested.glow:SetVertexColor(1, 0.8, 0.2)
        rested.glow:SetPoint("CENTER", rested.icon)
        rested.glow:SetSize(RESTED_SIZE * 1.65, RESTED_SIZE * 1.65)
        rested:EnableMouse(true)
        FG.Options.Tooltip(
            rested,
            T("Rested XP"),
            T("Your rested XP is below 0.5% of a level and Boosted Rested is inactive.")
        )
    end
    return strip
end

--- The secure button `i` (created out of combat): named and bound for the first five.
local function Button(i)
    if buttons[i] then return buttons[i] end
    local name = i <= BOUND and ("PWStrip" .. i) or nil
    local b = CreateFrame("Button", name, strip, "SecureActionButtonTemplate")
    b:RegisterForClicks("AnyUp", "AnyDown")
    b.binding = name and ("CLICK " .. name .. ":LeftButton") or nil
    AddButtonArt(b)
    -- Its step done during a fight (the button is locked until it ends): a check over it.
    b.done = b:CreateTexture(nil, "OVERLAY")
    b.done:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
    b.done:SetSize(SIZE * 0.6, SIZE * 0.6)
    b.done:SetPoint("CENTER", b.icon)
    b.done:Hide()
    local cooldown = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
    cooldown:SetAllPoints(b.icon)
    b.cooldown = cooldown
    -- The key it is bound to, over the icon's corner (as the game's action bars show theirs).
    if name then
        b.key = b:CreateFontString(nil, "OVERLAY")
        b.key:SetFontObject(KeyFont(SIZE))
        b.key:SetTextColor(1, 1, 1)
        b.key:SetJustifyH("RIGHT")
        b.key:SetWordWrap(false)
        b.key:SetPoint("TOPRIGHT", b.icon, "TOPRIGHT", 1, -1)
        b.key:Hide()
    end
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

--- The key each bound button answers to, over its icon (when asked). A text: at any time.
function Toolstrip:Keys()
    local on = FG:Get("toolstripKeys")
    for _, b in ipairs(buttons) do
        local label = rawget(b, "key")
        if label then
            local key = on and ActionOf(b) and b.binding and GetBindingKey and Readable(GetBindingKey(b.binding))
            local text = Toolstrip.KeyText(key)
            label:SetText(text)
            label:SetShown(text ~= "")
        end
    end
end

--- The counts after the names, as the quest log has them now. In a fight too: the texts move
--- on, the buttons keep their size. True when a count took another width, came or went: the
--- strip is to be laid out again (when the fight ends).
function Toolstrip:Counts()
    if not strip or not strip:IsShown() then return false end
    local resized = false
    for _, b in ipairs(buttons) do
        local a = ActionOf(b)
        if a and b:IsShown() then
            local count, shown = Toolstrip.Count(a), countOf[b]
            if (count == nil) ~= (shown == nil) then
                resized = true
            elseif shown and count ~= shown.text then
                shown.text = count
                b.count:SetText(shown.named and "(" .. count .. ")" or count)
                local width = math.ceil(tonumber(b.count:GetStringWidth()) or 0) + 2
                if width ~= shown.width then resized = true end
            end
        end
    end
    return resized
end

--- The quest log moved on: the counts with it, and the strip's layout when one changed width.
function Toolstrip:Progress()
    if not self:Counts() then return end
    if InCombatLockdown() then
        self.pending = true
    else
        self:Refresh()
    end
end

--- Lay the strip out for `actions` (out of combat).
local function Apply(actions, host, gap)
    if not Create() or not trash then return end
    local withRested = rested ~= nil and RestedAvailable()
    if rested then rested:SetShown(withRested) end
    local wanted = FG:Get("toolstrip")
        and (FG:Get("toolstripUnlocked") or FG:Get("guideShown"))
        and (actions[1] ~= nil or FG:Get("toolstripTrash") or withRested)
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
    -- Junk first, then a separator, then the bound step buttons, then the rested reminder.
    local L = Layout()
    local items = {}
    local withTrash = FG:Get("toolstripTrash") and true or false
    trash:SetShown(withTrash)
    if withTrash then
        local width, height = Dress(trash, BAG_FILTER_JUNK or "Junk", L)
        trash.columnWidth = width
        items[#items + 1] = { frame = trash, width = width, height = height }
        Toolstrip:RefreshTrash()
    end
    local withSeparator = withTrash and actions[1] ~= nil
    separator:SetShown(withSeparator)
    if withSeparator then items[#items + 1] = { frame = separator, separator = true } end
    -- In a row a short name (its distinctive word) under each icon; in a list the name whole.
    local labels = ShortNames(actions)
    for i, a in ipairs(actions) do
        local b = Button(i)
        Arm(b, a)
        local width, height = Dress(b, L.list and a.name or labels[i], L, Toolstrip.Count(a))
        items[#items + 1] = { frame = b, width = width, height = height }
    end
    for i = #actions + 1, #buttons do
        buttons[i].action = nil
        staleOf[buttons[i]] = nil
        buttons[i]:SetAttribute("type", nil)
        buttons[i]:SetAttribute("macrotext", nil)
        buttons[i]:Hide()
    end
    -- The reminder can appear in combat without moving or overlapping a secure action button:
    -- it has its place whether it shows or not, and only takes room when it does.
    if rested then
        items[#items + 1] = { frame = rested, width = RESTED_SIZE, height = RESTED_SIZE, absent = not withRested }
    end
    local widest, tallest = L.size, L.size
    for _, item in ipairs(items) do
        if not item.separator and not item.absent then
            widest, tallest = math.max(widest, item.width), math.max(tallest, item.height)
        end
    end
    -- From the strip's edge: the grip (where it is dragged by), then the icons.
    local edge = GRIP + GAP
    if L.list then
        local corner = L.right and "TOPRIGHT" or "TOPLEFT"
        local y = GAP
        for _, item in ipairs(items) do
            item.frame:ClearAllPoints()
            item.frame:SetPoint(corner, strip, corner, L.right and -edge or edge, -y)
            if item.separator then
                item.frame:SetSize(widest, SEPARATOR)
                y = y + SEPARATOR + GAP
            elseif not item.absent then
                y = y + item.height + GAP
            end
        end
        strip:SetWidth(edge + widest + GAP)
        strip:SetHeight(y)
    else
        local side = L.right and "RIGHT" or "LEFT"
        local x = edge
        for _, item in ipairs(items) do
            item.frame:ClearAllPoints()
            item.frame:SetPoint(side, strip, side, L.right and -x or x, 0)
            if item.separator then
                item.frame:SetSize(SEPARATOR, math.max(6, tallest - 6))
                x = x + SEPARATOR + GAP
            elseif not item.absent then
                x = x + item.width + GAP
            end
        end
        strip:SetWidth(x)
        strip:SetHeight(tallest + 2 * GAP)
    end
    strip:ClearAllPoints()
    if host then
        -- Docked over the guide, at its left corner or its right one.
        if L.right then
            strip:SetPoint("BOTTOMRIGHT", host, "TOPRIGHT", 0, gap)
        else
            strip:SetPoint("BOTTOMLEFT", host, "TOPLEFT", 0, gap)
        end
    else
        local state = FG.Guide:State()
        local point = state and state.toolstripPoint or DEFAULT_POINT
        strip:SetPoint(point[1], _G[point[2]] or UIParent, point[3], point[4], point[5])
    end
    strip:Show()
    Toolstrip:Keys()
    Toolstrip:Cooldowns()
    Toolstrip:Aim()
end

-- In the guide window ----------------------------------------------------------------------------
-- The same actions on buttons inside the guide's card (Card.lua), when asked: beside the step each
-- belongs to (`guideToolsSide`), in a row under the card's header (`guideToolsTop`), or both. The
-- icons alone: the name is in the step's line and in the tooltip. They are secure buttons of
-- their own, children of the card and placed from its corner where the card says its rows are
-- (Card.places); never anchored to a row, which could then not move during a fight. Like the
-- strip's, they change out of combat only: a step done during a fight leaves its button dimmed
-- and checked where it was until the fight ends.

--- What the card makes room for with these actions: nil for nothing, else { top = whether they
--- go in a row under the header, side = "left" or "right" of their step (nil: not there),
--- count = how many they are, of = { [step] = how many are its own } }.
function Toolstrip.Docking(actions)
    local side, top = FG:Get("guideToolsSide"), FG:Get("guideToolsTop") and true or false
    if side ~= "left" and side ~= "right" then side = nil end
    if not (side or top) or not actions or not actions[1] then return nil end
    local of = {}
    for _, a in ipairs(actions) do
        if a.step then of[a.step] = (of[a.step] or 0) + 1 end
    end
    return { top = top, side = side, count = #actions, of = of }
end

--- The same, for the card to draw by: during a fight, what its buttons are held to.
function Toolstrip:DockPlan(actions)
    if InCombatLockdown() then return self.dock end
    return Toolstrip.Docking(actions)
end

--- The card's buttons wanted for these actions, and the card: { action, x, y, size }, from the
--- card's top left corner. None in minimal mode, nor when the card drew no room for them.
local function DockWanted(actions)
    local out = {}
    local card = FG.Card and FG.Card.Frame and FG.Card:Frame()
    local places = FG.Card and FG.Card.places
    if not card or not places or not FG:Get("guideShown") or FG:Get("guideMode") == "minimal" then return out, card end
    local nth = {}
    for i, a in ipairs(actions) do
        local top = places.top
        if top then out[#out + 1] = { action = a, x = top.x + (i - 1) * top.step, y = top.y, size = top.size } end
        local row = a.step and places.rows[a.step]
        if row then
            local k = nth[a.step] or 0
            nth[a.step] = k + 1
            out[#out + 1] = { action = a, x = row.x + k * row.step, y = row.y, size = row.size }
        end
    end
    return out, card
end

--- What is asked of the card (see Docking) and where its buttons go: when either changes, the
--- buttons are placed again. During a fight the card draws by what it had (DockPlan), so the
--- places stay: what is asked tells that a setting changed meanwhile.
local function DockSignature(wanted, plan)
    local parts = { plan and ((plan.top and "top" or "") .. ":" .. (plan.side or "") .. ":" .. plan.count) or "" }
    for _, w in ipairs(wanted) do
        local a = w.action
        parts[#parts + 1] = table.concat({ a.kind, a.link or a.macro or "", w.x, w.y, w.size }, "\0")
    end
    return table.concat(parts, "\n")
end

--- The card's secure button `i` (created out of combat): its icon alone.
local function DockButton(i, card)
    if docked[i] then return docked[i] end
    local b = CreateFrame("Button", nil, card, "SecureActionButtonTemplate")
    b:RegisterForClicks("AnyUp", "AnyDown")
    -- Over the card's rows: the press is the button's, not the row's under it.
    b:SetFrameLevel((tonumber(card:GetFrameLevel()) or 1) + 10)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.done = b:CreateTexture(nil, "OVERLAY")
    b.done:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
    b.done:SetPoint("CENTER")
    b.done:Hide()
    local cooldown = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
    cooldown:SetAllPoints(b.icon)
    b.cooldown = cooldown
    b:SetScript("OnEnter", Tooltip)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetScript("PreClick", function(self) Toolstrip:Press(self) end)
    docked[i] = b
    return b
end

--- Put the card's buttons where they are wanted (out of combat).
local function ApplyDock(wanted, card)
    for i, w in ipairs(wanted) do
        local b = DockButton(i, card)
        Arm(b, w.action)
        b.place = w
        b:SetSize(w.size, w.size)
        b.done:SetSize(w.size * 0.6, w.size * 0.6)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", card, "TOPLEFT", w.x, w.y)
    end
    for i = #wanted + 1, #docked do
        local b = docked[i]
        b.action, b.place, staleOf[b] = nil, nil, nil
        b:SetAttribute("type", nil)
        b:SetAttribute("macrotext", nil)
        b:Hide()
    end
end

--- The card's buttons that show now, in order (for the card's own checks and the tests).
function Toolstrip.Docked()
    local out = {}
    for _, b in ipairs(docked) do
        if ActionOf(b) and b:IsShown() then out[#out + 1] = b end
    end
    return out
end

--- Follow these steps (the guide's steps to do, Guide.lua): now, or when combat ends. `actions`:
--- what Toolstrip.Actions made of them, when the guide has it already.
function Toolstrip:SetSteps(steps, actions)
    self.steps = steps or {}
    actions = actions or Toolstrip.Actions(self.steps)
    local signature = Signature(actions)
    local wanted, card = DockWanted(actions)
    local dockSignature = DockSignature(wanted, Toolstrip.Docking(actions))
    local state = FG.Guide:State()
    local host, gap
    if FG:Get("guideShown") and not (FG:Get("toolstripUnlocked") and state and state.toolstripPoint) then
        local minimal = FG:Get("guideMode") == "minimal"
        host = (minimal and FG.Mini or FG.Card):Frame()
        gap = 6 + (minimal and FG.Mini:TopInset() or 0) * FG:Get("scale")
    end
    -- The same buttons: only their counts may have moved on.
    local resized = self:Counts()
    local same = signature == self.signature
        and host == self.host
        and gap == self.gap
        and dockSignature == self.dockSignature
    if same and not self.pending and not resized then return end
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
        Each(function(b)
            local a = ActionOf(b)
            if a and b:IsShown() then
                staleOf[b] = not still[a.kind .. "\0" .. (a.link or a.macro or "")] or nil
                SetState(b, b.state)
            end
        end)
        return
    end
    self.pending = false
    Apply(actions, host, gap)
    if wanted[1] or docked[1] then
        ApplyDock(wanted, card)
        Toolstrip:Cooldowns()
        Toolstrip:Aim()
    end
    -- What the card drew room for, kept for it to draw by during a fight.
    self.dock = wanted[1] and Toolstrip.Docking(actions) or nil
    self.signature, self.host, self.gap, self.dockSignature = signature, host, gap, dockSignature
end

--- Again with the same steps (a setting changed).
function Toolstrip:Refresh()
    self.signature = nil
    self:SetSteps(self.steps)
end

--- The quest item's cooldown on its button.
function Toolstrip:Cooldowns()
    if not GetItemCooldown then return end
    Each(function(b)
        local a = ActionOf(b)
        if a and a.kind == "item" and b:IsShown() then
            local id = tonumber(a.link:match("item:(%d+)"))
            local start, duration = GetItemCooldown(id)
            if start then b.cooldown:SetCooldown(start, duration) end
        end
    end)
end

--- Show how every sword button stands with the mobs in sight (the press decides for itself).
function Toolstrip:Aim()
    -- The card's buttons too, whether the strip shows or not.
    if not (strip and strip:IsShown()) and not docked[1] then return end
    local on = FG:Get("targetSkipTapped")
    local found = {}
    Each(function(b)
        local a = ActionOf(b)
        if a and a.kind == "kill" and b:IsShown() then
            -- Looked for once a name: the same mob has a button on the strip and in the card.
            if found[a.name] == nil then
                found[a.name] = not InCombatLockdown() and Toolstrip.Pick(a.name, on) and true or false
            end
            SetState(b, found[a.name] and "aim" or "name")
            if GameTooltip:IsOwned(b) then Tooltip(b) end
        end
    end)
end

--- Back to targeting by name (combat starts: the buttons are fixed until it ends).
function Toolstrip:Unaim()
    if InCombatLockdown() then return end
    Each(function(b)
        local a = ActionOf(b)
        if a and (a.kind == "kill" or a.kind == "talk") then SetMacro(b, a.macro) end
        if a and a.kind == "kill" then SetState(b, "name") end
    end)
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
    -- With buttons in the card, the card first: it kept their room as it was during the fight.
    local inCard = Toolstrip.dock ~= nil or Toolstrip.Docking(Toolstrip.actions) ~= nil
    if Toolstrip.pending and inCard and FG.Guide and FG.Guide.Refresh then
        FG:Try("guide after the fight", FG.Guide.Refresh, FG.Guide)
    end
    if Toolstrip.pending then Toolstrip:SetSteps(Toolstrip.steps) end
    Toolstrip:Aim()
end)
FG:On("BAG_UPDATE_COOLDOWN", function() Toolstrip:Cooldowns() end)
-- The quest log moved on (a kill counted, in a fight too), or the keys were bound anew.
FG:On("QUEST_LOG_UPDATE", function() Toolstrip:Progress() end)
FG:On("UPDATE_BINDINGS", function() Toolstrip:Keys() end)
if FG.Edition == "forever" then
    for _, event in ipairs({ "PLAYER_ENTERING_WORLD", "UPDATE_EXHAUSTION", "PLAYER_XP_UPDATE", "PLAYER_REGEN_ENABLED" }) do
        FG:On(event, RefreshRested)
    end
    FG:On("UNIT_AURA", function(unit)
        if unit == "player" then RefreshRested() end
    end)
end
FG:On("BAG_UPDATE_DELAYED", function()
    Toolstrip:RefreshTrash()
    if trash and GameTooltip:IsOwned(trash) then TrashTooltip(trash) end
end)
FG:On("PLAYER_LOGIN", function()
    for _, key in ipairs({
        "toolstrip",
        "toolstripUnlocked",
        "scale",
        "toolstripTrash",
        "targetMark",
        "targetPing",
        "targetSkipTapped",
        "questItemButton",
    }) do
        FG:OnSetting(key, function() Toolstrip:Refresh() end)
    end
end)

--- Forget the free position and return above the guide.
function Toolstrip:ResetPosition()
    local state = FG.Guide and FG.Guide:State()
    if InCombatLockdown() then
        FG:Print(T("not possible in combat"))
        return
    end
    if state then state.toolstripPoint = nil end
    self:Refresh()
end

FG.Options:AddButton("toolstripTrash", {
    label = "Toolstrip back to its place",
    text = "Reset",
    run = function() Toolstrip:ResetPosition() end,
})
