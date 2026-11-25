-- Smoke test of the addon outside the game: minimal WoW API stubs, load files in TOC
-- order, fire login and quest events, check the guide advances.
-- Run from the repository root: luajit addon/tests/smoke.lua
-- `luajit addon/tests/smoke.lua profile`: Pathwright_Profile alone (the guide is another addon's).
local profileOnly = arg and arg[1] == "profile"

local onQuest, completed = {}, {}
local playerLevel = 1
local waypoint
local frames = {}

-- Generic UI object: any unknown method is a no-op returning another stub.
local function stub()
    local o = { events = {} }
    function o:RegisterEvent(e) self.events[e] = true end
    function o:SetScript(name, fn) self[name] = fn end
    function o:SetText(t) self.text = t end
    function o:GetText() return self.text end
    -- The game refuses a missing font.
    function o:SetFontObject(font) assert(font ~= nil, "SetFontObject without a font") end
    -- Strict as the newer clients' API: a boolean, not nil.
    function o:SetShown(shown)
        assert(type(shown) == "boolean", "SetShown(" .. tostring(shown) .. ")")
        self._shown = shown
    end
    function o:GetPoint() return "TOP", nil, "TOP", 0, 0 end
    function o:GetID() return 1 end
    function o:SetFrameLevel(level) self._level = level end
    function o:GetFrameLevel() return rawget(self, "_level") or 1 end
    function o:GetStringWidth() return #(rawget(self, "text") or "") * 5 end
    setmetatable(o, {
        __index = function()
            return function() return stub() end
        end,
    })
    return o
end

-- Frames know their name, parent and whether they are shown (a hidden parent hides its children);
-- in fields of their own, the addon sets its own fields on its frames (`strip.name`...).
CreateFrame = function(kind, name, parent, template)
    local f = stub()
    f._name, f._parent, f._shown, f._button = name, parent, true, kind == "Button"
    function f:SetBackdrop()
        assert(template and template:find("BackdropTemplate", 1, true), (name or kind) .. " needs BackdropTemplate")
    end
    function f:SetShown(value)
        assert(type(value) == "boolean", "SetShown(" .. tostring(value) .. ")")
        self._shown = value
    end
    function f:Show() self._shown = true end
    function f:Hide() self._shown = false end
    function f:SetAlpha(a) self._alpha = a end
    function f:GetAlpha() return self._alpha or 1 end
    function f:IsShown() return self._shown end
    function f:SetEnabled(enabled) self._enabled = enabled end
    function f:IsEnabled() return self._enabled ~= false end
    function f:GetName() return self._name end
    function f:SetAttribute(key, value)
        self._attributes = rawget(self, "_attributes") or {}
        self._attributes[key] = value
    end
    function f:GetAttribute(key) return (rawget(self, "_attributes") or {})[key] end
    function f:SetParent(p) self._parent = p end
    function f:GetParent() return self._parent end
    function f:HasScript(name) return name ~= "OnClick" or self._button == true end
    function f:GetScript(name) return rawget(self, name) end
    function f:IsVisible()
        local p = self._parent
        return self._shown and (not p or not p.IsVisible or p:IsVisible())
    end
    table.insert(frames, f)
    return f
end
CreateVector2D = function(x, y)
    return {
        GetXY = function() return x, y end,
    }
end
-- A UI suite the addon can take its look from (EllesmereUI's skinning API): it only keeps the
-- callback, called by the last test (until then no suite is ready, the addon has its own look).
EllesmereUI = { RegisterSkin = function(_, fn) EllesmereUI.skin = fn end }
-- The game's options (Blizzard_Settings), recorded: categories and their controls (initializers),
-- the proxy settings by variable, the category opened. Checks what the game checks (value types).
local options = { categories = {}, settings = {}, notified = {}, opened = nil }
MinimalSliderWithSteppersMixin = { Label = { Left = 1, Right = 2 } }
do
    local function Initializer(data)
        local init = { data = data, predicates = {} }
        function init:SetParentInitializer(parent, predicate)
            assert(parent and parent ~= self, "a parent initializer")
            self.parent = parent
            if predicate then table.insert(self.predicates, predicate) end
        end
        function init:AddModifyPredicate(predicate) table.insert(self.predicates, predicate) end
        function init:AddSearchTags() end
        function init:GetSetting() return self.data.setting end
        --- Whether the game lets it be changed now (its predicates).
        function init:Enabled()
            for _, predicate in ipairs(self.predicates) do
                if not predicate() then return false end
            end
            return true
        end
        return init
    end
    local function Category(name, parent, frame)
        local category = { name = name, parent = parent, frame = frame, initializers = {}, subcategories = {} }
        category.id = #options.categories + 1
        function category:GetID() return self.id end
        if parent then
            assert(not parent.registered, "subcategory " .. name .. " added after its category's registration")
            table.insert(parent.subcategories, category)
        end
        table.insert(options.categories, category)
        return category, category
    end
    local function Add(category, init)
        table.insert(category.initializers, init)
        return init
    end
    SettingsPanel = {
        GetLayout = function(_, category)
            return { AddInitializer = function(_, init) Add(category, init) end }
        end,
    }
    Settings = {
        VarType = { Boolean = "boolean", Number = "number", String = "string" },
        RegisterCanvasLayoutCategory = function(frame, name) return Category(name, nil, frame) end,
        RegisterVerticalLayoutCategory = function(name) return Category(name) end,
        RegisterCanvasLayoutSubcategory = function(parent, frame, name) return Category(name, parent, frame) end,
        RegisterVerticalLayoutSubcategory = function(parent, name) return Category(name, parent) end,
        RegisterAddOnCategory = function(category)
            assert(not category.parent, "a top category")
            category.registered = true
        end,
        RegisterProxySetting = function(category, variable, varType, name, default, get, set)
            assert(type(variable) == "string" and type(name) == "string", "variable and name")
            assert(type(default) == varType, variable .. ": default of type " .. type(default) .. ", not " .. varType)
            local setting =
                { variable = variable, varType = varType, name = name, default = default, category = category }
            function setting:GetValue() return get() end
            function setting:SetValue(value)
                assert(type(value) == varType, variable .. ": SetValue of type " .. type(value))
                if get() ~= value then set(value) end
            end
            function setting:SetValueToDefault() self:SetValue(default) end
            assert(not options.settings[variable], "registered twice: " .. variable)
            options.settings[variable] = setting
            return setting
        end,
        CreateCheckbox = function(category, setting, tooltip)
            assert(setting.varType == "boolean", "a check box for a boolean")
            return Add(
                category,
                Initializer({ kind = "checkbox", setting = setting, name = setting.name, tooltip = tooltip })
            )
        end,
        CreateSlider = function(category, setting, sliderOptions, tooltip)
            assert(setting.varType == "number" and sliderOptions, "a slider for a number")
            return Add(
                category,
                Initializer({
                    kind = "slider",
                    setting = setting,
                    name = setting.name,
                    options = sliderOptions,
                    tooltip = tooltip,
                })
            )
        end,
        CreateDropdown = function(category, setting, entries, tooltip)
            assert(type(entries) == "function", "the drop-down's entries")
            return Add(
                category,
                Initializer({
                    kind = "dropdown",
                    setting = setting,
                    name = setting.name,
                    options = entries,
                    tooltip = tooltip,
                })
            )
        end,
        CreateSliderOptions = function(min, max, step)
            local slider = { minValue = min, maxValue = max, steps = (max - min) / step, formatters = {} }
            function slider:SetLabelFormatter(labelType, fn)
                assert(labelType, "a label type")
                self.formatters[labelType] = fn
            end
            return slider
        end,
        CreateControlTextContainer = function()
            local container = { data = {} }
            function container:Add(value, label, tooltip)
                table.insert(self.data, { value = value, label = label, text = label, tooltip = tooltip })
            end
            function container:GetData() return self.data end
            return container
        end,
        NotifyUpdate = function(variable) options.notified[variable] = (options.notified[variable] or 0) + 1 end,
        OpenToCategory = function(id) options.opened = id end,
    }
    CreateSettingsListSectionHeaderInitializer = function(name, tooltip)
        return Initializer({ kind = "header", name = name, tooltip = tooltip })
    end
    CreateSettingsButtonInitializer = function(name, buttonText, onClick, tooltip, addSearchTags)
        assert(addSearchTags ~= nil, "addSearchTags is required")
        return Initializer({
            kind = "button",
            name = name,
            buttonText = buttonText,
            buttonClick = onClick,
            tooltip = tooltip,
        })
    end
end
--- The addon's category (Pathwright) in the game's options, and its page `name`.
function options.Category()
    for _, category in ipairs(options.categories) do
        if category.name == "Pathwright" and not category.parent then return category end
    end
end
function options.Page(name)
    for _, category in ipairs(options.Category().subcategories) do
        if category.name == name then return category end
    end
end
--- Every control of the addon's pages (initializers).
function options.Controls()
    local out = {}
    for _, category in ipairs(options.Category().subcategories) do
        for _, init in ipairs(category.initializers) do
            out[#out + 1] = init
        end
    end
    return out
end
local calls = {}
local function record(name)
    return function(...) calls[name] = { ... } end
end
AcceptQuest = record("AcceptQuest")
CompleteQuest = record("CompleteQuest")
GetQuestReward = record("GetQuestReward")
LootSlot = function(i) calls.loot = (calls.loot or 0) + 1 end
QuestGetAutoAccept = function() return false end
IsShiftKeyDown = function() return false end
IsQuestCompletable = function() return true end
GetNumQuestChoices = function() return 1 end
GetNumLootItems = function() return 3 end
GetCVarBool = function() return true end
IsModifiedClick = function() return false end
GetNumTrainerServices = function() return 0 end
IsTradeskillTrainer = function() return false end
GetMoney = function() return 0 end
IsInInstance = function() return false end
IsInGroup = function() return false end
IsInRaid = function() return false end
GetNumGroupMembers = function() return IsInGroup() and 2 or 0 end
UnitInParty = function() return false end
ObjectiveTrackerFrame = {
    hidden = false,
    Hide = function(self) self.hidden = true end,
    IsProtected = function() return false end,
    HookScript = function() end,
    Update = function() end,
}
GetQuestLogSpecialItemInfo = function() return nil end
GetDifficultyColor = function() return { r = 1, g = 0.8, b = 0 } end
C_PlayerInfo = {
    GetContentDifficultyQuestForPlayer = function() return 1 end,
}
GameTooltip = {
    SetOwner = function(self, owner) self.owner = owner end,
    SetHyperlink = function() end,
    Show = function() end,
    Hide = function(self) self.owner = nil end,
    SetText = function(self, text) self.lines = { text } end,
    AddLine = function(self, text) table.insert(self.lines, text) end,
    AddDoubleLine = function(self, left, right) table.insert(self.lines, left .. " | " .. right) end,
    IsOwned = function(self, frame) return self.owner == frame end,
}
-- Items: their class (12: quest items, the default) and how many are in the bags and the bank.
local itemClasses, bags, bank = {}, {}, {}
C_Item = {
    GetItemInfoInstant = function(id) return id, nil, nil, nil, 134400, itemClasses[id] or 12, 0 end,
    GetItemCount = function(id, includeBank) return (bags[id] or 0) + (includeBank and (bank[id] or 0) or 0) end,
}
UIParent = {}
print = print
strsplit = function(sep, s, n)
    local out, start = {}, 1
    while true do
        if n and #out == n - 1 then
            table.insert(out, s:sub(start))
            break
        end
        local i = s:find(sep, start, true)
        if not i then
            table.insert(out, s:sub(start))
            break
        end
        table.insert(out, s:sub(start, i - 1))
        start = i + 1
    end
    return unpack(out)
end
strmatch = string.match
ChatFontNormal = {}
strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
wipe = function(t)
    for k in pairs(t) do
        t[k] = nil
    end
    return t
end
time = os.time
date = os.date
GetTime = function() return os.clock() + 1000 end
GetLocale = function() return "frFR" end
UnitName = function() return "Brouz" end
GetNormalizedRealmName = function() return "Realm" end
UnitRace = function() return "Gnome", "Gnome", 7 end
UnitClass = function() return "Mage", "MAGE", 8 end
UnitFactionGroup = function() return "Alliance" end
UnitLevel = function() return playerLevel end
UnitXP = function() return 0 end
UnitXPMax = function() return 400 end
GetXPExhaustion = function() return 600 end
IsResting = function() return true end
local bindLocation = "Coldridge Valley"
GetBindLocation = function() return bindLocation end
GetInventoryItemID = function(_, slot) return slot == 5 and 6125 or nil end
local reloaded = false
ReloadUI = function() reloaded = true end
UnitGUID = function(u)
    if u == "npc" then return "Creature-0-1-2-3-658-0000" end
    return "Player-1-2"
end
StaticPopupDialogs = {}
StaticPopup_Show = record("StaticPopup_Show")
YES, NO = "Yes", "No"
UnitOnTaxi = function() return false end
UnitIsPlayer = function() return false end
UnitExists = function() return false end
InCombatLockdown = function() return false end
local macros = {}
GetMacroIndexByName = function(name)
    for i, m in pairs(macros) do
        if m.name == name then return i end
    end
    return 0
end
GetNumMacros = function() return 0, #macros end
CreateMacro = function(name, icon, body)
    table.insert(macros, { name = name, body = body })
    return #macros
end
EditMacro = function(i, name, icon, body) macros[i].body = body end
PickupMacro = function() end
issecretvalue = function() return false end
local timers = {}
C_Timer = { NewTicker = function() end, After = function(_, fn) table.insert(timers, fn) end }
--- Run the C_Timer.After callbacks waiting.
local function runTimers()
    local due = timers
    timers = {}
    for _, fn in ipairs(due) do
        fn()
    end
end
C_Map = {
    GetBestMapForUnit = function() return 1426 end,
    GetMapInfo = function(m) return { mapID = m, mapType = m == 1415 and 2 or 3, parentMapID = 1415 } end,
    GetPlayerMapPosition = function()
        return {
            GetXY = function() return 0.2993, 0.712 end,
        }
    end,
    CanSetUserWaypointOnMap = function() return true end,
    SetUserWaypoint = function(p) waypoint = p end,
    ClearUserWaypoint = function() waypoint = nil end,
    GetWorldPosFromMapPos = function(m, v)
        local x, y = v:GetXY()
        return 0, CreateVector2D(x * 1000, y * 1000)
    end,
}
UiMapPoint = {
    CreateFromCoordinates = function(m, x, y) return { m = m, x = x, y = y } end,
}
C_SuperTrack = {
    SetSuperTrackedUserWaypoint = function() end,
    SetSuperTrackedQuestID = function(q) C_SuperTrack.quest = q end,
}
C_QuestLog = {
    GetAllCompletedQuestIDs = function() return {} end,
    GetNumQuestLogEntries = function() return 0 end,
    GetInfo = function() return nil end,
    GetLogIndexForQuestID = function() return nil end,
    IsOnQuest = function(q) return onQuest[q] or false end,
    IsQuestFlaggedCompleted = function(q) return completed[q] or false end,
    IsComplete = function() return false end,
    GetQuestObjectives = function() return { { text = "Tough Wolf Meat: 0/8", finished = false } } end,
    GetTitleForQuestID = function() return nil end,
}
C_GossipInfo = {
    GetAvailableQuests = function() return { { questID = 233, questLevel = 2 } } end,
    GetActiveQuests = function() return {} end,
    SelectAvailableQuest = record("SelectAvailableQuest"),
    SelectActiveQuest = record("SelectActiveQuest"),
}
GetQuestID = function() return 179 end
SlashCmdList = {}

-- Each addon gets its own private table; the guide uses the profile's, the global `Pathwright`.
local function load(addon)
    local private = {}
    for line in io.lines("addon/" .. addon .. "/" .. addon .. ".toc") do
        -- Routes.lua and Services.lua ship empty: the guides of the tests instead, as an older app
        -- version wrote them. Config.lua ships empty too: as an older app wrote it, ignored.
        if line == "Config.lua" then
            assert(loadfile("addon/" .. addon .. "/Config.lua"))(addon, private)
            Pathwright.Config = { autoAccept = false, guideMode = "minimal", locale = "deDE", scale = 1.5 }
        elseif line == "Routes.lua" or line == "Services.lua" then
            assert(loadfile("addon/" .. addon .. "/" .. line))(addon, private)
            assert(loadfile("addon/tests/fixtures/" .. line))(addon, private)
        elseif line:match("%.lua$") then
            local chunk = assert(loadfile("addon/" .. addon .. "/" .. line:gsub("\\", "/")))
            chunk(addon, private)
        end
    end
end
-- Pathwright_Data (written by the desktop app) loads first. Alone with the profile part: what the
-- server has (its PathwrightSent) still drops the collector's rows.
if profileOnly then
    -- As the apps write it: the table last, one character a line (read as text, not run).
    PathwrightData = 'Pathwright.Routes = { x = { steps = {}, note = "PathwrightSent" } }\n'
        .. 'PathwrightSent = {\n  ["Brouz-Realm"] = 1,\n  ["Other-Realm"] = 9,\n}\n'
    PathwrightDataTime = 1700000000
end
load("Pathwright_Profile")
if not profileOnly then load("Pathwright_Guide") end
local FG = Pathwright

local Press, Key, Click, Option
do
    -- The key bindings (Bindings.xml): their Lua, run as the game runs them on a key press.
    local bindings = {}
    options.bindings = bindings
    if not profileOnly then
        local xml = assert(io.open("addon/Pathwright_Guide/Bindings.xml")):read("*a")
        for name, body in xml:gmatch('<Binding name="([^"]+)"[^>]*>(.-)</Binding>') do
            bindings[name] = body
        end
    end
    function Key(name) assert(loadstring(assert(bindings[name], "no binding " .. name)))() end

    --- A click on the button labelled `label` (English, shown translated) in the addon's options: on
    --- its main page or a row of its other pages.
    --- Shown with its parents (frames of the test's CreateFrame only).
    local function Visible(f)
        while type(f) == "table" do
            if rawget(f, "_shown") == false then return false end
            f = rawget(f, "_parent")
        end
        return true
    end
    function Click(label)
        local text = FG.T(label)
        for _, f in ipairs(frames) do
            if f._button and f:GetText() == text and Visible(f) and f:IsEnabled() then
                return f:GetScript("OnClick")(f, "LeftButton")
            end
        end
        for _, init in ipairs(options.Controls()) do
            if init.data.kind == "button" and init.data.name == text then return init.data.buttonClick() end
        end
        error("no button " .. label)
    end

    --- The setting `variable` of the addon's options, as its control changes it.
    function Option(variable) return assert(options.settings[variable], "no setting " .. variable) end
    local function Toggle(variable)
        local setting = Option(variable)
        setting:SetValue(not setting:GetValue())
    end

    -- What the chat commands did before: a key binding while playing, a button or a check box of the
    -- addon's options otherwise.
    local PRESS = {
        prev = function() Key("PATHWRIGHT_PREV") end,
        next = function() Key("PATHWRIGHT_NEXT") end,
        skip = function() Key("PATHWRIGHT_SKIP") end,
        undo = function() Key("PATHWRIGHT_UNDO") end,
        spot = function() Key("PATHWRIGHT_SPOT") end,
        mode = function() Key("PATHWRIGHT_MODE") end,
        guide = function() Key("PATHWRIGHT_GUIDE") end,
        hide = function() Key("PATHWRIGHT_UI") end,
        time = function() Key("PATHWRIGHT_TIME") end,
        status = function() Click("Recorded events") end,
        reset = function() Click("Clear the recorded events") end,
        export = function() Click("Export my character") end,
        profile = function() Click("Save the profile now") end,
        import = function() Click("Import a guide…") end,
        clear = function() Click("Delete the imported guides") end,
        compassReset = function() Click("Compass back to the top") end,
        restart = function() Click("Start over") end,
        debug = function() Toggle("Pathwright_debug") end,
        lock = function() Toggle("Pathwright_lockFrames") end,
        compass = function() Toggle("Pathwright_compassShown") end,
    }
    function Press(id) assert(PRESS[id], "nothing for " .. id)() end
end

local function fire(event, ...)
    for _, f in ipairs(frames) do
        if f.OnEvent and f.events[event] then f.OnEvent(f, event, ...) end
    end
end

GetAddOnMetadata = function(name, field) return name == "Pathwright_Profile" and field == "Version" and "0.13.0" or nil end
fire("ADDON_LOADED", "Pathwright_Profile")
-- The app learns the game loaded the addon, and which version.
assert(PathwrightDB.seen and PathwrightDB.seen.version == "0.13.0" and PathwrightDB.seen.time, "seen")
if not profileOnly then fire("ADDON_LOADED", "Pathwright_Guide") end
fire("PLAYER_LOGIN")
local char = PathwrightDB.characters["Brouz-Realm"]

-- Another addon shows the guide: this one only records, and does nothing else.
if profileOnly then
    assert(FG.Guide == nil and FG.Routes == nil and FG.Get == nil, "no guide without Pathwright_Guide")
    onQuest[179] = true
    fire("QUEST_DETAIL", 0)
    fire("QUEST_ACCEPTED", 179)
    assert(#char.events >= 2, "collector recorded events")
    assert(FG.DataSent["Brouz-Realm"] == 1 and PathwrightData == nil, "Pathwright_Data's sent seqs read, text let go")
    assert(FG.DataGuide == nil and FG.Routes == nil, "no guide kept without the guide part")
    -- The rows go on after the last the server has.
    assert(tonumber(char.events[1]:match("^(%d+)")) == 2, "numbered after the sent seq: " .. char.events[1])
    assert(char.guide == nil and waypoint == nil, "no guide state, no waypoint")
    assert(next(calls) == nil, "nothing done in game: " .. tostring(next(calls)))
    assert(FG.Options and FG.Options.category, "the options built at login")
    -- The addon's page in the game's options, with the profile part's own: the character on the
    -- main page, the Advanced page. `/pw` (a sub-command too) opens it and does nothing else.
    local category = options.Category()
    assert(category and category.registered and category.frame, "the addon's main page in the game's options")
    assert(#category.subcategories == 1 and options.Page("Avancé"), "only the Advanced page without the guide part")
    SlashCmdList.PATHWRIGHT("export")
    assert(options.opened == category:GetID(), "/pw opens the addon's page")
    assert(not (FG.TextWindow:Parts() and FG.TextWindow:Parts():IsShown()), "/pw export opens the options only")
    for _, f in ipairs(frames) do
        assert(not (f._button and f:GetText() == FG.T("Import a guide…")), "no guide button without the guide part")
    end
    -- Debug messages: a check box.
    Press("debug")
    assert(PathwrightDB.debug == true and Option("Pathwright_debug"):GetValue() == true, "debug on")
    Press("debug")
    assert(not PathwrightDB.debug, "debug off")
    -- Clearing the recorded events asks first (the game's dialog).
    local recorded = #char.events
    calls.StaticPopup_Show = nil
    Press("reset")
    assert(#char.events == recorded and calls.StaticPopup_Show[1] == "PATHWRIGHT_CLEAR_EVENTS", "asked first")
    StaticPopupDialogs.PATHWRIGHT_CLEAR_EVENTS.OnAccept()
    assert(#char.events == 0, "recorded events cleared")
    calls.StaticPopup_Show = nil
    fire("QUEST_ACCEPTED", 179)
    FG.Profile:Snapshot()
    local profile = PathwrightDB.profiles["Brouz-Realm"]
    assert(profile and profile.level == 1 and profile.class == "MAGE", "profile saved")
    -- The export needs nothing of the guide part.
    Press("export")
    local _, edit = FG.TextWindow:Parts()
    local json = LibStub("LibDeflate"):DecompressDeflate(LibStub("LibDeflate"):DecodeForPrint(edit:GetText():sub(6)))
    assert(json and json:find('"character":"Brouz-Realm"', 1, true), "export without the guide")
    assert(not json:find('"collector"', 1, true) and not json:find('"events"', 1, true), "no collector rows")
    assert(next(PathwrightDB.errors or {}) == nil, "no error: " .. tostring(next(PathwrightDB.errors or {})))
    print("profile only ok: " .. #char.events .. " events")
    os.exit(0)
end
assert(char.guide.route == "gnome-mage", "assigned route followed: " .. tostring(char.guide.route))

--- Choose a route for the character, as in the settings window's guides page, and follow it.
local function useRoute(name) FG.Guide:Choose(name) end
assert(char.guide.step == 1)
assert(waypoint and waypoint.m == 1426, "waypoint set")

onQuest[179] = true
fire("QUEST_DETAIL", 0)
fire("QUEST_ACCEPTED", 179)
assert(char.guide.step == 2, "advanced after accept, step " .. char.guide.step)

completed[179] = true
onQuest[179] = nil
fire("QUEST_TURNED_IN", 179, 80, 0)
assert(char.guide.step == 4, "objective and turn-in skipped, step " .. char.guide.step)

-- Back one page: steps 3 to 6 (Sten Stoutarm, Balir Frosthammer) are one group, step 2 another.
Press("prev")
assert(char.guide.step == 2, "the page before, step " .. char.guide.step)
Press("next")
assert(char.guide.step == 3, "the page after it, step " .. char.guide.step)
Press("status")
assert(#char.events >= 2, "collector recorded events")
print("smoke test ok: step " .. char.guide.step .. ", " .. #char.events .. " events")

-- On a page with steps left, the current step is its first one not done; the page stays.
FG.Guide:Advance()
assert(char.guide.step == 4 and FG.Guide:CurrentSteps()[1] == 3, "same page, its step not done yet")
-- Going back to a page done already stays there (refresh and quest events), the resync goes forward.
Press("prev")
FG.Guide:Advance()
assert(char.guide.step == 2, "stays after manual navigation")
fire("QUEST_LOG_UPDATE")
runTimers()
assert(char.guide.step == 2, "quest events do not move a manual position")
FG.Guide:Resync()
assert(char.guide.step == 4, "resync goes to the first step not done")
print("navigation ok")

-- Automation
fire("GOSSIP_SHOW")
assert(calls.SelectAvailableQuest and calls.SelectAvailableQuest[1] == 233, "gossip quest selected")
local detailID = GetQuestID
GetQuestID = function() return 233 end
fire("QUEST_DETAIL", 0)
assert(calls.AcceptQuest, "quest accepted")
GetQuestID = detailID
fire("QUEST_PROGRESS")
assert(calls.CompleteQuest, "quest completed")
fire("QUEST_COMPLETE")
assert(calls.GetQuestReward and calls.GetQuestReward[1] == 1, "single reward taken")
fire("LOOT_READY", false)
assert(calls.loot == 3, "all loot slots taken")
-- The guide's mode: switched in game and kept, the minimal strip shown instead of the card.
Press("mode")
assert(FG:Get("guideMode") == "minimal" and PathwrightDB.settings.guideMode == "minimal", "minimal mode kept")
assert(FG.Guide:Box() == FG.Mini:Frame(), "the minimal strip is the guide")
Press("mode")
assert(FG:Get("guideMode") == "full" and FG.Guide:Box() == FG.Card:Frame(), "back to the full card")

-- The settings of an older app's Config.lua are ignored: the defaults until chosen in game.
assert(FG.Config.autoAccept == false and FG:Get("autoAccept") == true, "Config.lua ignored")
assert(FG:Get("scale") == 1 and FG.Lang() == "frFR", "Config.lua's size and language ignored")
FG:Save("autoAccept", false)
calls.AcceptQuest = nil
fire("QUEST_DETAIL", 0)
assert(not calls.AcceptQuest, "auto accept turned off in game")
print("automation ok")

-- Quest tracker: lists the log, hides Blizzard's tracker.
C_QuestLog.GetNumQuestLogEntries = function() return 1 end
C_QuestLog.GetInfo = function(i) return { questID = 233, title = "Coldridge Valley Mail Delivery", level = 2 } end
onQuest[233] = true
assert(ObjectiveTrackerFrame.hidden, "Blizzard tracker hidden")
FG.Tracker:Refresh()
local next = FG.Guide:NextStepByQuest()
assert(next[233], "quest 233 found in the route")
print("tracker ok")

-- Professions: practice steps are done once the skill reaches their target.
local cooking = 20
GetProfessions = function() return nil, nil, nil, nil, 5, nil end
GetProfessionInfo = function(i) return "Cuisine", 0, cooking, 75, 0, 0, 185 end
FG.Routes["prof-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1,
    professions = {
        { key = "cooking", name = "Cooking", line = 185, target = 300, curve = { 0, 5, 10, 15, 20, 25, 30 } },
    },
    steps = {
        {
            k = "profession",
            t = "Learn Apprentice Cooking with Gremlock",
            e = "npc",
            id = 1699,
            n = "Gremlock",
            sk = 75,
            lvl = 5,
        },
        { k = "practice", t = "Raise Cooking to 25 (~7 min)", e = "skill", id = 185, n = "Cooking", sk = 25, lvl = 5 },
        { k = "grind", t = "Grind", lvl = 60 },
    },
}
-- No guide chosen and several made for a gnome mage: none followed; `/pw route` only opens the
-- addon's options.
FG.Assignments["Brouz-Realm"] = nil
useRoute(nil)
assert(char.guide.route == nil, "no chosen route, got " .. tostring(char.guide.route))
options.opened = nil
SlashCmdList.PATHWRIGHT("route gnome-mage")
assert(char.guide.route == nil, "/pw route does not switch, got " .. tostring(char.guide.route))
assert(options.opened == options.Category():GetID(), "/pw route opens the options")
-- Without a guide, the guide's keys do nothing.
Press("next")
Press("skip")
assert(char.guide.route == nil and char.guide.step, "nothing happens")
useRoute("prof-test")
assert(char.guide.step == 2, "rank already learned, step " .. char.guide.step)
cooking = 25
fire("SKILL_LINES_CHANGED")
assert(char.guide.step == 3, "practice done, step " .. char.guide.step)
playerLevel = 5
FG.Tracker:Refresh()
print("professions ok")

-- Skipping: outdated steps, exclusive alternatives, by hand.
playerLevel = 21
FG.Routes["skip-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1,
    steps = {
        { k = "accept", t = "Accept Old Quest", q = 5001, lvl = 1 },
        { k = "accept", t = "Accept Alt Quest", q = 5002, alt = { 5003 }, lvl = 21 },
        { k = "accept", t = "Accept Current Quest", q = 5004, lvl = 21 },
        { k = "turnin", t = "Turn in Current Quest", q = 5004, lvl = 21 },
        { k = "grind", t = "Grind", lvl = 60 },
    },
}
completed[5003] = true
useRoute("skip-test")
assert(char.guide.step == 3, "outdated and alternative steps skipped, step " .. char.guide.step)
Press("skip")
assert(char.guide.step == 5, "current quest skipped by hand, step " .. char.guide.step)
Press("undo")
assert(char.guide.step == 3, "undo brings the quest back, step " .. char.guide.step)
Press("undo")
assert(char.guide.step == 3, "nothing left to undo, step " .. char.guide.step)
print("skip ok")

-- An objective guide below the level its quests ask: the current step says so until it is reached.
do
    FG.Routes["objective-test"] = {
        race = 7,
        class = 8,
        faction = "Alliance",
        fromLevel = 21,
        toLevel = 21,
        time = 1,
        recommendedLevel = 25,
        steps = {
            { k = "accept", t = "Accept High Quest", q = 5101, lvl = 21 },
            { k = "turnin", t = "Turn in High Quest", q = 5101, lvl = 21 },
        },
    }
    local shown
    local card, mini = FG.Card.Render, FG.Mini.Render
    FG.Card.Render = function(_, view) shown = view end
    FG.Mini.Render = FG.Card.Render
    local function warned()
        shown = nil
        FG.Guide:Refresh()
        for _, c in ipairs(shown and shown.tasks[1] and shown.tasks[1].chips or {}) do
            if c.text == string.format(FG.T("Level %d recommended, you are %d"), 25, 21) then return true end
        end
        return false
    end
    useRoute("objective-test")
    assert(warned(), "the level recommended on the current step")
    playerLevel = 25
    assert(not warned(), "nothing once the level is reached")
    -- Made when the character was lower: its steps are not left behind (a leveling guide's are).
    for _, flagged in ipairs({ true, false }) do
        FG.Routes["objective-test"].levelsIgnored = flagged or nil
        FG.Routes["objective-test"].toLevel = flagged and 30 or 21 -- older guides: no flag, from = to
        useRoute("skip-test")
        useRoute("objective-test")
        assert(char.guide.step == 1, "objective guide's steps kept 4 levels up, step " .. char.guide.step)
    end
    playerLevel = 21
    FG.Card.Render, FG.Mini.Render = card, mini
    useRoute("skip-test")
end
print("recommended level ok")

-- Quest notes and icons (`nt`, `ic`): the step's icon says how it is done, a mark after its name
-- takes the color of its most important note, and the tooltip lists the notes.
do
    FG.Routes["notes-test"] = {
        race = 7,
        class = 8,
        faction = "Alliance",
        fromLevel = 21,
        toLevel = 21,
        time = 1,
        steps = {
            {
                k = "accept",
                t = "Accept Secret Quest",
                q = 5102,
                lvl = 21,
                ic = "event",
                nt = { { l = 3, t = "Read me" }, { l = 1, t = "Good to know" } },
            },
            { k = "turnin", t = "Turn in Secret Quest", q = 5102, lvl = 21 },
        },
    }
    local shown
    local card, mini = FG.Card.Render, FG.Mini.Render
    FG.Card.Render = function(_, view) shown = view end
    FG.Mini.Render = FG.Card.Render
    useRoute("notes-test")
    FG.Guide:Refresh()
    local task = shown.tasks[1]
    assert(task.icon == "Interface\\Icons\\INV_Misc_PocketWatch_01", "the event icon: " .. tostring(task.icon))
    assert(task.mark:find("UI%-Dialog%-Icon%-AlertNew") and task.mark:find(":255:40:40|t", 1, true), "a red mark")
    assert(not task.name:find("|T", 1, true), "the name alone for the compass")
    local lines = {}
    local addLine = GameTooltip.AddLine
    GameTooltip.AddLine = function(_, text) table.insert(lines, text) end
    FG.Guide:StepTooltip({}, 1)
    GameTooltip.AddLine = addLine
    assert(lines[2]:find("Read me", 1, true) and lines[3]:find("Good to know", 1, true), "the notes in the tooltip")
    FG.Card.Render, FG.Mini.Render = card, mini
    useRoute("skip-test")
end
print("quest notes ok")

-- Progress belongs to its guide: a quest marked done by hand in one is still to do in another,
-- and coming back finds the marks again. A new version keeps the quests, not the step marks.
Press("skip")
FG.Routes["other-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 21,
    toLevel = 60,
    time = 1,
    steps = {
        { k = "accept", t = "Accept Current Quest", q = 5004, lvl = 21 },
        { k = "turnin", t = "Turn in Current Quest", q = 5004, lvl = 21 },
    },
}
useRoute("other-test")
assert(char.guide.step == 1 and not char.guide.skippedQuests[5004], "marked in another guide only")
useRoute("skip-test")
assert(char.guide.step == 5 and char.guide.skippedQuests[5004], "back to the first guide")
char.guide.marks[1] = "skip"
FG.Routes["skip-test"].time = 2
useRoute("other-test")
useRoute("skip-test")
assert(not char.guide.marks[1] and char.guide.skippedQuests[5004], "new version")
print("progress per guide ok")

-- A book for the library (GitHub #29): looting it is the accept, the librarian offers the
-- quest only then, taken and turned in together.
FG.Routes["held-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1,
    steps = {
        {
            k = "accept",
            t = "Loot The Dalaran Digest, Vol. 23",
            q = 78127,
            hd = true,
            e = "item",
            id = 209844,
            lvl = 21,
        },
        { k = "turnin", t = "Accept The Dalaran Digest and turn it in", q = 78127, e = "npc", id = 211033, lvl = 21 },
        { k = "grind", t = "Grind", lvl = 60 },
    },
}
useRoute("held-test")
assert(char.guide.step == 1, "the book is not in the bags yet")
bags[209844] = 1
fire("BAG_UPDATE_DELAYED")
assert(char.guide.step == 2, "the book looted: on to the librarian, step " .. char.guide.step)
assert(FG.Guide:WantsQuest(78127), "taken at the librarian")
onQuest[78127] = true
assert(not FG.Guide:WantsQuest(78127), "taken")
onQuest[78127], bags[209844], completed[78127] = nil, nil, true
fire("QUEST_TURNED_IN", 78127, 155, 0)
assert(char.guide.step == 3, "turned in, step " .. char.guide.step)
completed[78127] = nil
print("held item ok")

-- A quest of the log the guide does not take is abandoned first: the step is done once it has
-- left the log.
FG.Routes["abandon-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 21,
    toLevel = 60,
    time = 1,
    steps = {
        { k = "abandon", t = "Abandon Unused Quest (not in this guide)", q = 7001, lvl = 21 },
        { k = "accept", t = "Accept Current Quest", q = 5004, lvl = 21 },
    },
}
onQuest[7001] = true
local untitled = C_QuestLog.GetTitleForQuestID
C_QuestLog.GetTitleForQuestID = function(q) return q == 7001 and "Quête inutile" or nil end
useRoute("abandon-test")
assert(char.guide.step == 1, "waits while the quest is in the log, step " .. char.guide.step)
-- The game's name of the quest, then the label and why, once each.
local abandonRow = FG.Guide:Box().rows[1]
local abandonLine = abandonRow.name:GetText() .. " / " .. abandonRow.sub:GetText()
assert(
    abandonLine:find("Abandon", 1, true)
        and abandonLine:find("Quête inutile", 1, true)
        and abandonLine:find("(not in this guide)", 1, true)
        and not abandonLine:find("Unused Quest", 1, true),
    "abandon line: " .. abandonLine
)
C_QuestLog.GetTitleForQuestID = untitled
onQuest[7001] = nil
fire("QUEST_REMOVED", 7001)
assert(char.guide.step == 2, "quest abandoned, step " .. char.guide.step)
print("abandon ok")

-- Checkpoints: reached in level before the planned step, the steps up to it are skipped but the
-- kept ones (a chain going on after it).
playerLevel = 22
FG.Routes["checkpoint-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1,
    checkpoints = { { lvl = 22, step = 5 } },
    steps = {
        { k = "accept", t = "Accept Filler", q = 6001, lvl = 20 },
        { k = "accept", t = "Accept Chain", q = 6002, kp = true, lvl = 20 },
        { k = "turnin", t = "Turn in Filler", q = 6001, lvl = 21 },
        { k = "turnin", t = "Turn in Chain", q = 6002, kp = true, lvl = 21 },
        { k = "accept", t = "Accept New Hub Quest", q = 6003, lvl = 22 },
        { k = "accept", t = "Accept Chain Follow-up", q = 6004, lvl = 22 },
    },
}
useRoute("checkpoint-test")
assert(char.guide.step == 1, "checkpoint route starts at 1, step " .. char.guide.step)
FG.Guide:SkipAhead()
assert(char.guide.marks[1] == "skip" and char.guide.marks[3] == "skip", "filler skipped")
assert(not char.guide.marks[2] and not char.guide.marks[4], "chain kept")
assert(char.guide.step == 2, "on the kept chain, step " .. char.guide.step)
playerLevel = 21
onQuest[6002] = true
FG.Guide:Advance()
FG.Guide:SkipAhead()
assert(not char.guide.marks[4], "no skip below the checkpoint level")
onQuest[6002] = nil
print("checkpoints ok")

-- A quest whose accept was left behind: its turn-in is not asked.
playerLevel = 21
FG.Routes["turnin-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1,
    steps = {
        { k = "accept", t = "Accept Keeper of the Flame", q = 6001, lvl = 10 },
        { k = "turnin", t = "Turn in Keeper of the Flame", q = 6001, lvl = 20 },
        { k = "accept", t = "Accept Current Quest", q = 6002, lvl = 21 },
    },
}
useRoute("turnin-test")
assert(char.guide.step == 3, "turn-in of a never accepted quest skipped, step " .. char.guide.step)
print("accept-skipped ok")

-- Background objectives do not block the guide; the tracker keeps them as in progress.
playerLevel = 5
onQuest[7001] = true
FG.Routes["bg-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1,
    steps = {
        { k = "accept", t = "Accept Gold Dust Exchange", q = 7001, lvl = 5 },
        { k = "objective", t = "Gold Dust x10", q = 7001, o = 1, n = "Gold Dust", bg = true, lvl = 5 },
        { k = "accept", t = "Accept Next Quest", q = 7002, lvl = 5 },
        { k = "turnin", t = "Turn in Gold Dust Exchange", q = 7001, lvl = 6 },
    },
}
useRoute("bg-test")
assert(char.guide.step == 3, "background objective passed, step " .. char.guide.step)
assert(FG.Guide:NextStepByQuest()[7001].bg, "background quest in progress for the tracker")
print("background ok")

-- In progress: a background objective left behind stays listed, and comes before the turn-in of
-- its quest while not done.
do
    local listed
    local set = FG.Toolstrip.SetSteps
    FG.Toolstrip.SetSteps = function(self, steps)
        listed = steps
        return set(self, steps)
    end
    onQuest[7001], onQuest[7002] = true, true
    FG.Guide:Resync()
    assert(char.guide.step == 4, "on the turn-in, step " .. char.guide.step)
    assert(listed[1] and listed[1].k == "objective" and listed[1].q == 7001, "objective before its turn-in")
    assert(listed[2] and listed[2].k == "turnin", "then the turn-in")
    FG.Toolstrip.SetSteps = set
    onQuest[7001], onQuest[7002] = nil, nil
end
print("in progress ok")

-- Toolstrip: a sword per mob of the current step, a speech bubble for its NPC, the trash can.
playerLevel = 5
FG.Routes["macro-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1,
    steps = {
        {
            k = "objective",
            t = "Kill Kobold Vermin x8",
            q = 7101,
            o = 1,
            e = "npc",
            id = 6,
            n = "Kobold Vermin",
            mobs = { "Kobold Vermin" },
            lvl = 5,
        },
        { k = "turnin", t = "Turn in Kobold Camp", q = 7101, e = "npc", id = 197, n = "Marshal McBride", lvl = 5 },
    },
}
onQuest[7101] = true
useRoute("macro-test")
do
    local strip = FG.Toolstrip
    local function named(name)
        for i = #frames, 1, -1 do
            if frames[i]:GetName() == name then return frames[i] end
        end
    end
    local function Kinds()
        local out = {}
        for _, a in ipairs(strip.actions) do
            table.insert(out, a.kind .. ":" .. a.name)
        end
        return table.concat(out, ", ")
    end
    assert(Kinds() == "kill:Kobold Vermin", "a sword for the step's mob: " .. Kinds())
    local kill = strip.actions[1].macro
    assert(kill:find("/targetexact Kobold Vermin", 1, true) and kill:find("/cleartarget [dead]", 1, true), kill)
    -- The skull once the target is found: /tm on WoW Forever (its macros' /run SetRaidTarget is
    -- blocked), cleared first so that a second press does not take it off.
    assert(
        FG.Edition == "forever"
            and kill:find("/cleartarget [dead]\n/stopmacro [@target,noexists]\n/tm 0\n/tm 8", 1, true)
            and not kill:find("/run", 1, true),
        "the skull with /tm on Forever: " .. kill
    )
    assert(not kill:find("/ping", 1, true), "no ping without the client's ping system")
    local first = named("PWStrip1")
    assert(first and first.action == strip.actions[1] and first:IsShown(), "the first bound button armed")
    assert(named("PathwrightToolstrip"):IsShown() and named("PathwrightTrash"):IsShown(), "strip and trash can shown")
    -- The trash can first, then a separator, then the step's buttons.
    local trashAt, firstAt = {}, {}
    named("PathwrightTrash").SetPoint = function(_, ...) trashAt = { ... } end
    named("PWStrip1").SetPoint = function(_, ...) firstAt = { ... } end
    strip:Refresh()
    assert(trashAt[4] and firstAt[4] and trashAt[4] < firstAt[4], "the trash can left of the step's buttons")
    assert(firstAt[4] - trashAt[4] > named("PathwrightTrash").columnWidth + 4, "a separator between them")
    strip:SetSteps({ { mobs = { "Highland Strider", "Highland Thrasher" } } })
    assert(first.caption:GetText() == "Strider" and named("PWStrip2").caption:GetText() == "Thrasher")
    assert(
        first.action.name == "Highland Strider" and first.action.macro:find("/targetexact Highland Strider", 1, true)
    )
    strip:SetSteps({ { mobs = { "Highland Raptor", "Young Raptor" } } })
    assert(first.caption:GetText() == "Highland" and named("PWStrip2").caption:GetText() == "Young")
    assert(_G["BINDING_NAME_CLICK PWStrip1:LeftButton"], "the button's binding named")
    Press("next")
    assert(Kinds() == "talk:Marshal McBride", "a speech bubble for the turn-in's NPC: " .. Kinds())
    -- Cleared first: an NPC out of reach is not found, and the last one must not stay targeted.
    assert(strip.actions[1].macro == "/cleartarget\n/targetexact Marshal McBride", strip.actions[1].macro)
    -- The world ping (WoW Forever): Attack on a mob to kill, On My Way on an NPC to talk to, by
    -- the number of its ping type (the words only match on English clients).
    SLASH_PING1 = "/ping"
    assert(strip.KillMacro("Kobold Vermin"):find("/tm 8\n/ping [@target] 0", 1, true), "Attack ping")
    assert(
        strip.TalkMacro("Marshal McBride")
            == "/cleartarget\n/targetexact Marshal McBride\n/stopmacro [@target,noexists]\n/ping [@target] 3",
        "On My Way ping, no skull on an NPC: " .. strip.TalkMacro("Marshal McBride")
    )
    Enum = Enum or {}
    Enum.PingSubjectType = { Attack = 7 }
    assert(strip.KillMacro("Kobold Vermin"):find("/ping [@target] 7", 1, true), "the client's own number")
    Enum.PingSubjectType = nil
    FG:Save("targetPing", false)
    assert(not strip.KillMacro("Kobold Vermin"):find("/ping", 1, true), "no ping when not asked")
    assert(
        strip.TalkMacro("Marshal McBride") == "/cleartarget\n/targetexact Marshal McBride",
        "nothing after the talk target"
    )
    FG:Save("targetPing", nil)
    SLASH_PING1 = nil
    FG.Edition = "classic"
    local classic = strip.KillMacro("Kobold Vermin")
    assert(classic:find("SetRaidTarget", 1, true) and not classic:find("/tm", 1, true), "skull on Classic: /run")
    FG:Save("targetMark", false)
    assert(not strip.KillMacro("Kobold Vermin"):find("SetRaidTarget", 1, true), "no skull when not asked")
    FG:Save("targetMark", nil)
    FG.Edition = "forever"
    -- In combat the secure buttons keep their actions; the change waits for the fight's end.
    Press("prev")
    InCombatLockdown = function() return true end
    Press("next")
    assert(strip.pending and named("PWStrip1").action.kind == "kill", "nothing changed in combat")
    InCombatLockdown = function() return false end
    fire("PLAYER_REGEN_ENABLED")
    assert(not strip.pending and named("PWStrip1").action.kind == "talk", "changed when combat ended")
    -- Its layout, from the settings: a row or a list, from the left or from the right, the
    -- icons' size and the names' length.
    do
        local guideSteps = strip.steps
        local mobs = { { mobs = { "Highland Strider", "Highland Thrasher" } } }
        local one, two, bar = named("PWStrip1"), named("PWStrip2"), named("PathwrightToolstrip")
        local at = {}
        local function watch(frame, key)
            frame.SetPoint = function(_, ...) at[key] = { ... } end
        end
        watch(one, "one")
        watch(two, "two")
        watch(one.icon, "icon")
        watch(one.caption, "caption")
        watch(bar, "bar")
        local function set(key, value)
            FG:Save(key, value)
            strip:SetSteps(mobs)
        end
        set("toolstripLayout", "list")
        assert(one.caption:GetText() == "Highland Strider", "a list shows the whole name")
        assert(at.one[1] == "TOPLEFT" and at.two[5] < at.one[5], "a list: one button under the other")
        assert(
            at.icon[1] == "LEFT" and at.caption[1] == "LEFT" and at.caption[3] == "RIGHT",
            "left: the name right of the icon"
        )
        assert(at.bar[1] == "BOTTOMLEFT", "held by the guide's left corner")
        set("toolstripSide", "right")
        assert(at.one[1] == "TOPRIGHT" and at.icon[1] == "RIGHT", "right: the icons at the right edge")
        assert(at.caption[1] == "RIGHT" and at.caption[3] == "LEFT", "the name runs left and ends at the icon")
        assert(at.bar[1] == "BOTTOMRIGHT", "held by the guide's right corner")
        set("toolstripNameLength", 8)
        assert(one.caption:GetText() == "Highland...", "names cut to the length asked: " .. one.caption:GetText())
        set("toolstripNameLength", 0)
        assert(one.caption:GetText() == "", "no names at 0")
        set("toolstripNameLength", nil)
        set("toolstripLayout", nil)
        assert(at.one[1] == "RIGHT" and at.one[4] < 0 and at.two[4] < at.one[4], "a row from the right edge")
        assert(one.caption:GetText() == "Strider", "a row keeps the short names")
        set("toolstripSide", nil)
        assert(at.one[1] == "LEFT" and at.one[4] > 0, "and from the left, as before")
        local size
        one.icon.SetSize = function(_, w) size = w end
        set("toolstripIcon", 30)
        assert(size == 30 and strip.Layout().size == 30, "the icons' size")
        set("toolstripIcon", 500)
        assert(strip.Layout().size == 48, "within what the setting allows")
        set("toolstripIcon", nil)
        -- The letters' size: the line under the icons grows with it.
        local height
        one.SetSize = function(_, _, h) height = h end
        set("toolstripFont", 14)
        assert(strip.Layout().font == 14 and height == 24 + 16, "larger letters, a taller line: " .. tostring(height))
        set("toolstripFont", 99)
        assert(strip.Layout().font == 20, "within what the setting allows")
        set("toolstripFont", nil)
        assert(strip.Layout().font == 10 and height == 24 + 12, "and back: " .. tostring(height))
        one.SetSize = nil
        -- A text a UI suite wrote its font on keeps that size whatever font object comes later
        -- (the game pins it): the size is then written on the text itself.
        do
            local pinned = { size = 10 }
            function pinned:SetFontObject() end
            function pinned:GetFont() return "Fonts\\Suite.ttf", self.size, "OUTLINE" end
            function pinned:SetFont(path, size, flags)
                self.path, self.size, self.flags = path, size, flags
            end
            FG.Skin:Resize(pinned, 14)
            assert(pinned.size == 14 and pinned.flags == "OUTLINE", "a pinned text takes the size, keeps its face")
            pinned.path = nil
            FG.Skin:Resize(pinned, 14)
            assert(pinned.path == nil, "nothing written when the size is already right")
        end
        assert(
            strip.Limited("Élan des bois", 4) == "Élan..." and strip.Limited("Wolf", 4) == "Wolf",
            "cut between characters"
        )
        one.SetPoint, two.SetPoint, one.icon.SetPoint, one.caption.SetPoint, bar.SetPoint = nil, nil, nil, nil, nil
        one.icon.SetSize = nil
        strip:SetSteps(guideSteps)
    end
    -- The key a button is bound to over its icon, and its objective's count after its name.
    do
        local guideSteps = strip.steps
        local one, two = named("PWStrip1"), named("PWStrip2")
        -- A text of the stubs knows SetShown alone.
        local function shown(text) return rawget(text, "_shown") == true end
        assert(strip.KeyText("SHIFT-F") == "s-F" and strip.KeyText("F5") == "F5", "a modifier as one letter")
        assert(strip.KeyText("ALT-CTRL-BUTTON4") == "a-c-M4" and strip.KeyText("NUMPAD7") == "N7", "long names short")
        assert(strip.KeyText("CTRL--") == "c--" and strip.KeyText("MOUSEWHEELUP") == "WU", "a dash is a key too")
        assert(strip.KeyText(nil) == "", "no key, no text")
        local bound = { ["CLICK PWStrip1:LeftButton"] = "SHIFT-1" }
        local binding = GetBindingKey
        GetBindingKey = function(command) return bound[command] end
        local have = 3
        local objectives, isOn = C_QuestLog.GetQuestObjectives, C_QuestLog.IsOnQuest
        C_QuestLog.IsOnQuest = function(q) return q == 7301 or isOn(q) end
        C_QuestLog.GetQuestObjectives = function(q)
            if q ~= 7301 then return objectives(q) end
            return { { text = "Raptor Head: " .. have .. "/10", numFulfilled = have, numRequired = 10 } }
        end
        local steps = {
            {
                k = "objective",
                q = 7301,
                o = 1,
                n = "Raptor Head",
                mobs = { "Highland Strider", "Highland Thrasher" },
            },
            { k = "turnin", q = 7302, e = "npc", n = "Marshal McBride" },
        }
        strip:SetSteps(steps)
        assert(one.key:GetText() == "s-1" and shown(one.key), "the key over the icon: " .. tostring(one.key:GetText()))
        assert(not shown(two.key), "none over a button without a key")
        bound["CLICK PWStrip2:LeftButton"] = "BUTTON4"
        fire("UPDATE_BINDINGS")
        assert(two.key:GetText() == "M4" and shown(two.key), "bound anew, shown at once")
        FG:Save("toolstripKeys", false)
        strip:SetSteps(steps)
        assert(not shown(one.key) and not shown(two.key), "no keys when turned off")
        FG:Save("toolstripKeys", nil)
        strip:SetSteps(steps)
        assert(shown(one.key), "and back")
        -- Every mob of the step has the step's count; the NPC of a turn-in has none.
        assert(one.caption:GetText() == "Strider" and one.count:GetText() == "(3/10)", "the count after the name")
        assert(two.count:GetText() == "(3/10)" and not shown(named("PWStrip3").count), "a turn-in has no count")
        have = 4
        fire("QUEST_LOG_UPDATE")
        assert(one.count:GetText() == "(4/10)" and two.count:GetText() == "(4/10)", "it follows the quest log")
        -- In a fight the text moves on; a wider one is laid out when the fight ends.
        InCombatLockdown = function() return true end
        have = 5
        fire("QUEST_LOG_UPDATE")
        assert(one.count:GetText() == "(5/10)" and not strip.pending, "counted during a fight")
        have = 10
        fire("QUEST_LOG_UPDATE")
        assert(one.count:GetText() == "(10/10)" and strip.pending, "a wider count waits for the fight's end")
        local width
        one.SetSize = function(_, w) width = w end
        InCombatLockdown = function() return false end
        fire("PLAYER_REGEN_ENABLED")
        assert(not strip.pending and width, "then the strip is laid out again")
        one.SetSize = nil
        have = 3
        FG:Save("toolstripLayout", "list")
        strip:SetSteps(steps)
        assert(one.caption:GetText() == "Highland Strider" and one.count:GetText() == "(3/10)", "in a list too")
        FG:Save("toolstripNameLength", 0)
        strip:SetSteps(steps)
        assert(one.caption:GetText() == "" and one.count:GetText() == "3/10", "bare without a name")
        FG:Save("toolstripNameLength", nil)
        FG:Save("toolstripLayout", nil)
        FG:Save("toolstripProgress", false)
        strip:SetSteps(steps)
        assert(not shown(one.count) and strip.Count(strip.actions[1]) == nil, "no counts when turned off")
        FG:Save("toolstripProgress", nil)
        C_QuestLog.GetQuestObjectives, C_QuestLog.IsOnQuest = objectives, isOn
        GetBindingKey = binding
        strip:SetSteps(guideSteps)
    end
    -- Turned off: the strip goes.
    FG:Save("toolstrip", false)
    assert(not named("PathwrightToolstrip"):IsShown(), "the strip hidden when turned off")
    FG:Save("toolstrip", nil)
    assert(named("PathwrightToolstrip"):IsShown(), "and back")
end
print("toolstrip ok")

-- The addon's font: one of those the player's addons share, chosen in the options, taken at once
-- by every font object and by the texts a UI suite wrote its own font on.
do
    local Skin = FG.Skin
    local locale = GetLocale
    GetLocale = function() return "enUS" end
    assert(#Skin.Fonts() == 4 and Skin.FontFile() == nil, "without the library: the game's four, none chosen")
    assert(Skin.FontFile("Morpheus") == "Fonts\\MORPHEUS.TTF", "one of the game's by its name")
    GetLocale = function() return "koKR" end
    assert(#Skin.Fonts() == 0 and Skin.FontFile("Morpheus") == nil, "none of them where they cannot write the language")
    GetLocale = locale
    -- The library the addons share their fonts through.
    local shared =
        { Expressway = "Interface\\AddOns\\Shared\\Expressway.ttf", ["Friz Quadrata TT"] = "Fonts\\FRIZQT__.TTF" }
    local media = LibStub:NewLibrary("LibSharedMedia-3.0", 1)
    function media:List(kind)
        local names = {}
        for name in pairs(kind == "font" and shared or {}) do
            names[#names + 1] = name
        end
        table.sort(names)
        return names
    end
    function media:Fetch(kind, name) return kind == "font" and shared[name] or nil end
    assert(table.concat(Skin.Fonts(), ",") == "Expressway,Friz Quadrata TT", "the fonts shared, in order")
    -- Its choice in the options: the default, then each font.
    local function Entries()
        for _, init in ipairs(options.Controls()) do
            if init.data.kind == "dropdown" and init.data.name == FG.T("Addon font") then return init.data.options() end
        end
    end
    local entries = assert(Entries(), "the font's drop-down")
    assert(#entries == 3 and entries[1].value == "" and entries[2].value == "Expressway", "the default first")
    -- Font objects as the game makes them.
    local createFont, gameFont = CreateFont, GameFontNormal
    CreateFont = function(name)
        local font = { name = name }
        function font:SetFont(path, size, flags)
            if path == "missing.ttf" then return false end
            self.path, self.size, self.flags = path, size, flags
            return true
        end
        function font:GetFont() return self.path, self.size, self.flags end
        function font:SetShadowColor() end
        function font:SetShadowOffset() end
        function font:SetTextColor() end
        return font
    end
    GameFontNormal = { GetFont = function() return "Fonts\\GAME.TTF", 12, "" end }
    local font = Skin.FontObject(37)
    assert(font.path == "Fonts\\GAME.TTF" and font.size == 37, "the game's font until one is chosen")
    Option("Pathwright_uiFont"):SetValue("Expressway")
    assert(FG:Get("uiFont") == "Expressway" and Skin.FontFile() == shared.Expressway, "chosen in the options")
    assert(font.path == shared.Expressway and font.size == 37, "the font objects take it at once, same size")
    assert(Skin.FontObject(38).path == shared.Expressway, "and those made later")
    -- A font whose file cannot be read, or whose addon is gone: the game's own.
    shared.Broken = "missing.ttf"
    FG:Save("uiFont", "Broken")
    assert(font.path == "Fonts\\GAME.TTF", "a file that cannot be read: the game's font")
    FG:Save("uiFont", "Expressway")
    shared.Expressway = nil
    Skin:ApplyFont()
    assert(font.path == "Fonts\\GAME.TTF" and Skin.FontFile() == nil, "a font that is gone: the game's font")
    entries = Entries()
    assert(
        entries[#entries].value == "Expressway" and entries[#entries].label:find("Expressway", 1, true),
        "still listed, as gone"
    )
    FG:Save("uiFont", nil)
    assert(FG:Get("uiFont") == "" and font.path == "Fonts\\GAME.TTF", "back to the default")
    CreateFont, GameFontNormal = createFont, gameFont
    shared["Friz Quadrata TT"] = nil
end
print("font ok")

-- The sword's press, out of combat: one mob in sight, alive and not tagged by someone else, then
-- the checker clears a wrong target at once, else puts the skull and the ping on it.
do
    local strip = FG.Toolstrip
    local function named(name)
        for i = #frames, 1, -1 do
            if frames[i]:GetName() == name then return frames[i] end
        end
    end
    Press("prev")
    assert(strip.actions[1] and strip.actions[1].kind == "kill", "back on the kill step")
    local sword, checker = named("PWStrip1"), named("PWStripCheck")
    assert(sword.PreClick and checker and checker.PreClick, "the press and the checker")
    local saved = {
        plates = C_NamePlate,
        name = UnitName,
        dead = UnitIsDead,
        tapped = UnitIsTapDenied,
        attack = UnitCanAttack,
        exists = UnitExists,
        unit = UnitIsUnit,
    }
    local mobs = {}
    local function Plate(unit, x, y)
        local plate = CreateFrame("Frame", nil, UIParent)
        plate.namePlateUnitToken = unit
        plate.GetCenter = function() return x, y end
        plate.GetEffectiveScale = function() return 1 end
        plate.IsForbidden = function() return false end
        plate.IsAnchoringRestricted = function() return false end
        return plate
    end
    local list = {}
    C_NamePlate = { GetNamePlates = function() return list end, GetNamePlateForUnit = function() end }
    UIParent.GetCenter = function() return 500, 400 end
    UIParent.GetEffectiveScale = function() return 1 end
    UnitName = function(u) return mobs[u] and mobs[u].name or "Brouz" end
    UnitIsDead = function(u) return mobs[u] and mobs[u].dead or false end
    UnitIsTapDenied = function(u) return mobs[u] and mobs[u].tapped or false end
    UnitCanAttack = function(_, u) return mobs[u] ~= nil and not mobs[u].friend end
    UnitExists = function(u) return mobs[u] ~= nil end
    UnitIsUnit = function(a, b) return a == b end
    mobs.nameplate1 = { name = "Kobold Vermin", tapped = true }
    mobs.nameplate2 = { name = "Kobold Vermin" }
    mobs.nameplate3 = { name = "Kobold Vermin" }
    mobs.nameplate4 = { name = "Kobold Vermin", dead = true }
    mobs.nameplate5 = { name = "Kobold Worker" }
    list = {
        Plate("nameplate1", 500, 400), -- tagged, right in the middle
        Plate("nameplate2", 900, 100), -- far from the middle
        Plate("nameplate3", 560, 420), -- the closest one to aim at
        Plate("nameplate4", 501, 401), -- dead
        Plate("nameplate5", 500, 400), -- another name
    }
    -- A press: by name (the game picks the nearest, in sight or not), then the checker, then the
    -- skull, stopped when the checker cleared the target. (The tagged one aside for now.)
    local tappedPlate = table.remove(list, 1)
    sword.PreClick(sword)
    local byName = strip.CheckedMacro(strip.actions[1])
    assert(sword.aimed == byName, "by name: " .. tostring(sword.aimed))
    assert(byName:find("^/cleartarget\n/targetexact Kobold Vermin\n/cleartarget %[dead%]\n/click PWStripCheck"), byName)
    assert(
        byName:find("/click PWStripCheck\n/stopmacro [@target,noexists]\n/tm 0\n/tm 8", 1, true),
        "then the checker, then the skull (stopped when the checker cleared the target): " .. byName
    )
    assert(strip.expect.name == "Kobold Vermin" and strip.expect.kind == "kill", "the checker told what to expect")
    -- The ping in the sword's own macro, after the checker: the game does not ping from a macro
    -- run by /click.
    SLASH_PING1 = "/ping"
    local pinged = strip.CheckedMacro(strip.actions[1])
    SLASH_PING1 = nil
    local click, ping = pinged:find("/click PWStripCheck", 1, true), pinged:find("/ping [@target]", 1, true)
    assert(click and ping and click < ping, "the ping after the checker, in the sword's macro: " .. pinged)
    -- The game's pick is fit: kept, the skull and the ping on it.
    mobs.target = { name = "Kobold Vermin" }
    checker.PreClick(checker)
    assert(checker.macro == "", "the right mob: nothing for the checker to do: " .. tostring(checker.macro))
    assert(strip.expect == nil, "one check per press")
    -- Its macro runs on the edge of the click it gets: a /click is a down on WoW Forever when
    -- "cast on key down" is on.
    checker.PreClick(checker, "LeftButton", true)
    assert(checker:GetAttribute("useOnKeyDown") == true, "a down click: acts on the down")
    checker.PreClick(checker, "LeftButton", false)
    assert(checker:GetAttribute("useOnKeyDown") == false, "an up click: acts on the up")
    -- Not fit (another name, tagged, dead, friendly): cleared, so the sword's macro stops before
    -- the skull and the ping (WoW Forever targets no nameplate unit from a macro: none instead).
    for _, wrong in ipairs({
        { name = "Kobold Worker" },
        { name = "Kobold Vermin", tapped = true },
        { name = "Kobold Vermin", dead = true },
        { name = "Kobold Vermin", friend = true },
    }) do
        sword.PreClick(sword)
        mobs.target = wrong
        checker.PreClick(checker)
        assert(checker.macro == "/cleartarget", "a wrong target cleared: " .. tostring(checker.macro))
    end
    -- A unit function the game refuses (an error) is no fact; a press that fails on the way is by
    -- name with the checker all the same, never the plain macro of combat.
    CheckInteractDistance = function() error("protected") end
    assert(strip.Pick("Kobold Vermin", true), "a refused range check: no error")
    CheckInteractDistance = nil
    local plates = C_NamePlate.GetNamePlates
    C_NamePlate.GetNamePlates = function() error("refused") end
    sword.aimed = nil
    sword.PreClick(sword)
    assert(
        sword.aimed == byName and strip.expect and strip.expect.skipTapped,
        "by name and checked: " .. tostring(sword.aimed)
    )
    C_NamePlate.GetNamePlates = plates
    mobs.target = nil
    -- A target already fit: kept, the skull and the ping on it (no target taken by name).
    mobs.target = { name = "Kobold Vermin" }
    sword.PreClick(sword)
    assert(sword.aimed == strip.KeepMacro() and not sword.aimed:find("targetexact"), "kept: " .. sword.aimed)
    assert(sword.aimed:find("^/stopmacro %[@target,noexists%]\n/tm 0\n/tm 8"), sword.aimed)
    mobs.target = { name = "Kobold Vermin", tapped = true }
    sword.PreClick(sword)
    assert(sword.aimed == byName, "a tagged target is not kept")
    mobs.target = nil
    -- A tagged one in sight as near as the nearest fit one (the same range, or none measured): the
    -- game could take either, so by name without the skull and the ping.
    table.insert(list, 1, tappedPlate)
    local how, sure = strip.Plan("Kobold Vermin", true)
    assert(how == "name" and not sure, "as near: by name, not sure")
    sword.PreClick(sword)
    assert(sword.aimed == strip.NameMacro("Kobold Vermin", false), "no skull nor ping: " .. sword.aimed)
    assert(not sword.aimed:find("/tm", 1, true) and not sword.aimed:find("/click", 1, true), sword.aimed)
    -- Among those in sight: the current target first (not when the checker looks for another).
    UnitIsUnit = function(a, b) return (a == "nameplate2" and b == "target") or a == b end
    assert(strip.Pick("Kobold Vermin", true) == "nameplate2", "the current target first")
    assert(strip.Pick("Kobold Vermin", true, true) == "nameplate3", "another than the target")
    UnitIsUnit = function(a, b) return a == b end
    -- The nearest to the player before the closest to the middle of the screen: within the
    -- interaction distances (10, then 28 yards), then the player's own harmful spells' ranges.
    local near = {}
    CheckInteractDistance = function(u, index) return near[u] ~= nil and near[u] <= ({ [3] = 10, [4] = 28 })[index] end
    local book =
        { { name = "Fireball", range = 35 }, { name = "Frost Nova", range = 0 }, { name = "Shoot", range = 30 } }
    GetNumSpellTabs = function() return 1 end
    GetSpellTabInfo = function() return "General", nil, 0, #book end
    GetSpellBookItemName = function(i) return book[i].name end
    IsHarmfulSpell = function() return true end
    GetSpellInfo = function(n)
        for _, sp in ipairs(book) do
            if sp.name == n then return n, nil, nil, nil, 0, sp.range end
        end
    end
    IsSpellInRange = function(spell, u)
        local r = (GetSpellInfo(spell) and select(6, GetSpellInfo(spell))) or 0
        return near[u] ~= nil and near[u] <= r and 1 or 0
    end
    fire("SPELLS_CHANGED")
    near.nameplate2 = 8
    assert(strip.Range("nameplate2") == 10 and strip.Range("nameplate3") == math.huge, "ranges measured")
    how, sure = strip.Plan("Kobold Vermin", true)
    assert(how == "name" and sure, "a fit one nearer than the tagged one: by name, sure")
    sword.PreClick(sword)
    assert(sword.aimed == byName, "then by name, the skull and the ping: " .. sword.aimed)
    near.nameplate1 = 9
    how, sure = strip.Plan("Kobold Vermin", true)
    assert(how == "name" and not sure, "a tagged one at the same range: not sure")
    -- The nearest tagged: by name and one Tab to the next enemy, the skull and the ping when it is
    -- for sure a fit one; not when another enemy is as near.
    near.nameplate1, near.nameplate2 = 8, 20
    how, sure = strip.Plan("Kobold Vermin", true)
    assert(how == "tab" and sure, "tab to the fit one")
    sword.PreClick(sword)
    local tab = strip.TabMacro("Kobold Vermin", true)
    assert(sword.aimed == tab, "tab: " .. sword.aimed)
    assert(tab:find("^/cleartarget\n/targetexact Kobold Vermin\n/targetenemy\n/cleartarget %[dead%]\n/stopmacro"), tab)
    near.nameplate5 = 20
    how, sure = strip.Plan("Kobold Vermin", true)
    assert(how == "tab" and not sure, "another enemy as near: not sure")
    sword.PreClick(sword)
    assert(sword.aimed == strip.TabMacro("Kobold Vermin", false) and not sword.aimed:find("/tm"), sword.aimed)
    near.nameplate1, near.nameplate2, near.nameplate5 = nil, 8, nil
    assert(
        strip.Pick("Kobold Vermin", true) == "nameplate2",
        "the mob next to the player, off the middle of the screen"
    )
    near.nameplate2, near.nameplate3 = 33, 29
    assert(
        strip.Range("nameplate2") == 35 and strip.Range("nameplate3") == 30,
        "spell ranges: " .. strip.Range("nameplate3")
    )
    assert(strip.Pick("Kobold Vermin", true) == "nameplate3", "within the shorter spell's range")
    near.nameplate2, near.nameplate3 = 20, 20
    assert(strip.Pick("Kobold Vermin", true) == "nameplate3", "the same range: the closest to the middle")
    CheckInteractDistance, IsSpellInRange, GetNumSpellTabs, GetSpellTabInfo = nil, nil, nil, nil
    GetSpellBookItemName, IsHarmfulSpell, GetSpellInfo = nil, nil, nil
    fire("SPELLS_CHANGED")
    -- A restricted nameplate (an instance): the game refuses to measure it; never asked.
    local restricted = Plate("nameplate9", 500, 400)
    restricted.IsForbidden = function() return true end
    restricted.GetCenter = function() error("Can't measure restricted regions") end
    mobs.nameplate9 = { name = "Kobold Vermin" }
    table.insert(list, restricted)
    assert(strip.Pick("Kobold Vermin", true), "a restricted plate skipped, no error")
    table.remove(list)
    mobs.nameplate9 = nil
    -- Every one in sight tagged: never dimmed, the press still does something (Tab), no skull nor
    -- ping; a wrong pick the checker sees is cleared.
    mobs.nameplate2.tapped, mobs.nameplate3.tapped = true, true
    strip:Aim()
    assert(sword:GetAlpha() == 1 and sword.state ~= "tapped", "all tagged: still enabled")
    sword.PreClick(sword)
    assert(sword.aimed == strip.TabMacro("Kobold Vermin", false), "all tagged: tab, no skull nor ping: " .. sword.aimed)
    mobs.target = { name = "Kobold Vermin", tapped = true }
    checker.PreClick(checker)
    assert(checker.macro == "/cleartarget", "a wrong target cleared at once: " .. tostring(checker.macro))
    sword.PreClick(sword)
    mobs.target = nil
    checker.PreClick(checker)
    assert(checker.macro == "", "no target and none fit: nothing to do")
    -- None in sight: by name all the same.
    list = {}
    strip:Aim()
    assert(sword.state == "name", "none in sight")
    sword.PreClick(sword)
    assert(sword.aimed == byName, "none in sight: by name")
    -- Turned off: a tagged mob kept.
    FG:Save("targetSkipTapped", false)
    sword.PreClick(sword)
    mobs.target = { name = "Kobold Vermin", tapped = true }
    checker.PreClick(checker)
    assert(checker.macro == "", "a tagged mob kept when not asked")
    mobs.target = nil
    FG:Save("targetSkipTapped", nil)
    -- An NPC to talk to, out of reach: the target is cleared before looking for it (the last
    -- step's NPC never stays targeted), and the checker clears any other NPC that got targeted.
    local talk = strip.CheckedMacro({ kind = "talk", name = "Marshal McBride" })
    assert(talk:find("^/cleartarget\n/targetexact Marshal McBride\n/click PWStripCheck"), talk)
    strip.expect = { name = "Marshal McBride", kind = "talk" }
    mobs.target = { name = "Deputy Willem", friend = true }
    checker.PreClick(checker)
    assert(checker.macro == "/cleartarget", "the last step's NPC cleared: " .. tostring(checker.macro))
    mobs.target = nil
    -- In combat nothing changes; at its start the buttons go back to their macros by name.
    local before = sword.aimed
    InCombatLockdown = function() return true end
    sword.PreClick(sword)
    assert(sword.aimed == before, "no change in combat")
    InCombatLockdown = function() return false end
    fire("PLAYER_REGEN_DISABLED")
    assert(sword.aimed == strip.actions[1].macro and checker.macro == "", "by name in combat, the checker emptied")
    -- Its step done during a fight: the button is locked, so it shows done (dimmed, a check),
    -- then leaves once the fight is over (as PLAYER_REGEN_ENABLED does).
    local steps = strip.steps
    InCombatLockdown = function() return true end
    strip:SetSteps({})
    assert(strip.IsStale(sword) and sword:GetAlpha() < 0.5, "done in combat: dimmed")
    assert(sword:IsShown() and rawget(sword, "action"), "still there while the fight lasts")
    InCombatLockdown = function() return false end
    strip:SetSteps(strip.steps)
    assert(not sword:IsShown() and not rawget(sword, "action") and not strip.IsStale(sword), "gone after the fight")
    -- Nothing left to show: the strip hides, and its buttons are emptied (keys still click them).
    FG:Save("toolstripTrash", false)
    strip:SetSteps(steps)
    strip:SetSteps({})
    assert(not rawget(sword, "action") and not sword:IsShown(), "hidden strip: buttons emptied")
    FG:Save("toolstripTrash", nil)
    strip:SetSteps(steps)
    assert(sword:IsShown() and not strip.IsStale(sword) and sword:GetAlpha() == 1, "back, not marked")
    C_NamePlate, UnitName, UnitIsDead, UnitIsTapDenied = saved.plates, saved.name, saved.dead, saved.tapped
    UnitCanAttack, UnitExists, UnitIsUnit = saved.attack, saved.exists, saved.unit
    Press("next")
end
print("aiming ok")

-- Talent plan: the next talent follows the class plan (mage: Improved Frostbolt x5, then
-- Elemental Precision).
local frostbolt = 2
GetNumTalentTabs = function() return 3 end
GetNumTalents = function(tab) return tab == 3 and 2 or 0 end
GetTalentInfo = function(tab, i)
    if i == 1 then return "Improved Frostbolt", nil, 1, 2, frostbolt, 5 end
    return "Elemental Precision", nil, 1, 3, 0, 3
end
assert(FG.Talents:Next().name == "Improved Frostbolt", "next talent: Improved Frostbolt")
frostbolt = 5
assert(FG.Talents:Next().name == "Elemental Precision", "next talent after 5/5: Elemental Precision")
print("talents ok")

-- Leveling time against the plan.
playerLevel = 3
FG.Routes["timing-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1000,
    levels = { [2] = 100, [3] = 300 },
    steps = {
        { k = "accept", t = "Accept", q = 7201, lvl = 3 },
    },
}
useRoute("timing-test")
FG.Guide:State().levelTimes = { [3] = 240 }
assert(FG.Timing:Short():find("1 min", 1, true), "timing ahead of plan: " .. FG.Timing:Short())
print("timing ok")

-- Flight master: the current fly step's destination is taken.
local taken
Enum = Enum or {}
Enum.FlightPathState = { Current = 0, Reachable = 1, Unreachable = 2 }
GetTaxiMapID = function() return 1415 end
C_TaxiMap = {
    GetAllTaxiNodes = function()
        return { { nodeID = 2, slotIndex = 7, state = 1 }, { nodeID = 6, slotIndex = 3, state = 1 } }
    end,
}
TakeTaxiNode = function(slot) taken = slot end
FG.Routes["fly-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1,
    steps = {
        { k = "fly", t = "Fly to Ironforge", e = "taxi", id = 6, n = "Ironforge", lvl = 3 },
    },
}
useRoute("fly-test")
for _, f in ipairs(frames) do
    if f.events.TAXIMAP_OPENED and f.OnEvent then f:OnEvent("TAXIMAP_OPENED") end
end
assert(taken == 3, "flight to the step's node taken")
print("auto fly ok")

-- The flight map's arrow (Taxi.lua): over the destination of the guide's fly step, found by
-- its flight point, or by its name where the client lists none; none where it cannot be flown to.
do
    local Taxi = FG.Taxi
    local step = FG.Guide:Route().steps[1]
    assert(Taxi.Wanted() == step, "the flight the guide asks for")
    local slot, reachable = Taxi.Slot(step)
    assert(slot == 3 and reachable, "the destination's button, by its flight point")
    TaxiButton3 = CreateFrame("Button", "TaxiButton3")
    Taxi.open = true
    assert(Taxi:Show() == TaxiButton3 and Taxi.arrow:IsShown(), "the arrow over the destination")
    -- It bobs along a sine: after one whole bob it is back where it began, nothing to jump from.
    local bob = Taxi.arrow:GetScript("OnUpdate")
    bob(Taxi.arrow, 0.225)
    assert(Taxi.arrow.clock == 0.225, "the bob follows the time")
    bob(Taxi.arrow, 0.9)
    assert(math.abs(Taxi.arrow.clock - 0.225) < 1e-9, "one bob on, it is where it was")
    FG:Save("taxiArrow", false)
    assert(Taxi:Show() == nil and not Taxi.arrow:IsShown(), "no arrow with its setting off")
    FG:Save("taxiArrow", nil)
    -- A client that lists no flight points: by name, without the zone.
    local realNodes = C_TaxiMap.GetAllTaxiNodes
    C_TaxiMap.GetAllTaxiNodes = function() return {} end
    NumTaxiNodes = function() return 4 end
    TaxiNodeName = function(i) return i == 3 and "Ironforge, Dun Morogh" or "Elsewhere, Far Away" end
    TaxiNodeGetType = function() return "REACHABLE" end
    assert(Taxi.Slot(step) == 3, "by its name")
    -- Not learned yet: no arrow, said once in the chat.
    TaxiNodeGetType = function() return "DISTANT" end
    local said = {}
    local realPrint = FG.Print
    FG.Print = function(_, fmt, ...) said[#said + 1] = string.format(fmt, ...) end
    assert(Taxi:Show() == nil and Taxi:Show() == nil and not Taxi.arrow:IsShown(), "no arrow where one cannot fly")
    assert(#said == 1 and said[1]:find("Ironforge", 1, true), "said once: " .. tostring(said[1]))
    -- The map closed (the flight taken): nothing shown, nothing said.
    Taxi.open, Taxi.told = false, nil
    assert(Taxi:Show() == nil and #said == 1, "nothing once the map has closed")
    FG.Print = realPrint
    C_TaxiMap.GetAllTaxiNodes = realNodes
    NumTaxiNodes, TaxiNodeName, TaxiNodeGetType, TaxiButton3 = nil, nil, nil, nil
    print("flight map arrow ok")
end

-- Two flights in a row: taking off on the first does not do the second; it waits for its own
-- take-off.
do
    local up, savedTaxi = false, UnitOnTaxi
    UnitOnTaxi = function() return up end
    FG.Routes["fly-two"] = {
        race = 7,
        class = 8,
        faction = "Alliance",
        fromLevel = 1,
        toLevel = 60,
        time = 1,
        steps = {
            { k = "fly", t = "Fly to Ironforge", e = "taxi", id = 6, n = "Ironforge", lvl = 3 },
            { k = "fly", t = "Fly to Stormwind", e = "taxi", id = 2, n = "Stormwind", lvl = 3 },
        },
    }
    useRoute("fly-two")
    FG.Guide:Advance()
    assert(char.guide.step == 1, "no flight yet: step " .. char.guide.step)
    up = true
    FG.Guide:Advance()
    FG.Guide:Advance()
    assert(char.guide.step == 2, "first flight taken, the second waits: step " .. char.guide.step)
    up = false
    FG.Guide:Advance()
    assert(char.guide.step == 2, "landed: the second still waits, step " .. char.guide.step)
    up = true
    FG.Guide:Advance()
    assert(char.guide.step == 3, "second flight taken: step " .. char.guide.step)
    UnitOnTaxi = savedTaxi
    useRoute("fly-test")
    print("two flights ok")
end

-- A kill-and-loot note (`hv`): done once the item is in the bags, not before.
do
    FG.Routes["loot-note-test"] = {
        race = 7,
        class = 8,
        faction = "Horde",
        fromLevel = 1,
        toLevel = 60,
        time = 1,
        steps = { { k = "note", t = "Kill Samuel Fipps and loot his remains", hv = 16333, lvl = 4 } },
    }
    useRoute("loot-note-test")
    local step = FG.Guide:Route().steps[1]
    assert(not FG.Guide:IsDone(step, 1), "loot note: not done without the item")
    bags[16333] = 1
    assert(FG.Guide:IsDone(step, 1), "loot note: done once the item is in the bags")
    bags[16333] = nil
    -- With the quest the item is used for (`hq`), the note stays done once the item is used up.
    FG.Routes["loot-note-test"].steps[1].hq = 6395
    FG.Routes["loot-note-test"].steps[2] = { k = "note", t = "Bury the remains", lvl = 4 }
    assert(not FG.Guide:IsDone(step, 1), "loot note: not done without the item or the quest")
    local objectives, isComplete = C_QuestLog.GetQuestObjectives, C_QuestLog.IsComplete
    local fulfilled = false
    C_QuestLog.GetQuestObjectives = function(q)
        if q ~= 6395 then return objectives(q) end
        local n = fulfilled and 1 or 0
        return { { text = "Samuel's Remains: " .. n .. "/1", numFulfilled = n, numRequired = 1, finished = fulfilled } }
    end
    C_QuestLog.IsComplete = function(q)
        if q == 6395 then return fulfilled end
        return isComplete(q)
    end
    -- On the quest at 0/1 without the item (taken before the kill): not done.
    onQuest[6395] = true
    assert(not FG.Guide:IsDone(step, 1), "loot note: not done on the quest at 0/1")
    -- The item looted: the guide moves on by itself.
    useRoute("loot-note-test")
    assert(FG.Guide:CurrentStep() == 1, "loot note: stops at the note")
    bags[16333] = 1
    FG.Guide:Advance()
    assert(FG.Guide:CurrentStep() == 2, "loot note: moves on once looted: " .. FG.Guide:CurrentStep())
    bags[16333] = nil
    -- The item used up, the objective fulfilled: done.
    fulfilled = true
    assert(FG.Guide:IsDone(step, 1), "loot note: done once the objective is fulfilled")
    fulfilled = false
    C_QuestLog.GetQuestObjectives, C_QuestLog.IsComplete = objectives, isComplete
    onQuest[6395] = nil
    completed[6395] = true
    assert(FG.Guide:IsDone(step, 1), "loot note: done once the quest is turned in")
    completed[6395] = nil
end

-- The kill-and-loot notes of the built-in guides, as the builder wrote them: done once the item is
-- in the bags, and still done once the quest it is for is turned in.
do
    local notes = {
        { "Desolace3436", "Flayed Demon Skin", 20310, 1480 },
        { "Ashenvale2628", "Etched Phial", 5867, 1195 },
        { "DesolaceShendralas4343", "Tattered Journal", 260347, 93644 },
        { "WesternEasternPlaguelands5658", "Dalson Cabinet Key", 12739, 5060 },
    }
    local register = FG.Builtin.Register
    for _, n in ipairs(notes) do
        local def
        FG.Builtin.Register = function(d) def = d end
        assert(loadfile("addon/Pathwright_Guide/Builtin/" .. n[1] .. ".lua"))()
        FG.Builtin.Register = register
        local found
        for _, st in ipairs(def.steps) do
            if st.k == "note" and st.t:find(n[2], 1, true) then found = st end
        end
        assert(found and found.hv == n[3] and found.hq == n[4], n[1] .. ": the note carries hv and hq")
        FG.Routes["builtin-loot-test"] = {
            race = 7,
            class = 8,
            faction = "Horde",
            fromLevel = 1,
            toLevel = 60,
            time = 1,
            steps = { found },
        }
        useRoute("builtin-loot-test")
        assert(not FG.Guide:IsDone(found, 1), n[1] .. ": not done without the item")
        bags[n[3]] = 1
        assert(FG.Guide:IsDone(found, 1), n[1] .. ": done with the item in the bags")
        bags[n[3]] = nil
        completed[n[4]] = true
        assert(FG.Guide:IsDone(found, 1), n[1] .. ": still done once the quest is turned in")
        completed[n[4]] = nil
    end
end

-- Hearth steps: passed when the hearthstone is on a long cooldown, kept when it is ready or
-- nearly so.
do
    local cd, saved = { 0, 0 }, C_Container
    C_Container = { GetItemCooldown = function() return cd[1], cd[2], 1 end }
    FG.Routes["hearth-test"] = {
        race = 7,
        class = 8,
        faction = "Alliance",
        fromLevel = 1,
        toLevel = 60,
        time = 1,
        steps = {
            { k = "hearth", t = "Use your hearthstone", lvl = 3 },
            { k = "note", t = "Cooldown check item,6948,>0,1. Hearth to Everlook", lvl = 3 },
        },
    }
    local function probe(start, duration)
        cd = { start, duration }
        useRoute("hearth-test")
        local steps = FG.Guide:Route().steps
        return (FG.Guide:IsDone(steps[1], 1)) and true or false, (FG.Guide:IsDone(steps[2], 2)) and true or false
    end
    local a, b = probe(0, 0)
    assert(not a and not b, "hearthstone ready: steps stay")
    a, b = probe(GetTime() - 120, 3600)
    assert(a and b, "long cooldown: steps passed")
    a, b = probe(GetTime() - 3500, 3600)
    assert(not a and not b, "nearly ready: steps stay")
    -- Long cooldown, Astral Recall known and ready: the step stays.
    local savedSpell, savedKnown = C_Spell, IsPlayerSpell
    C_Spell = { GetSpellCooldown = function() return { startTime = 0, duration = 0 } end }
    IsPlayerSpell = function(id) return id == 556 end
    a, b = probe(GetTime() - 120, 3600)
    assert(not a and not b, "astral recall ready: steps stay")
    C_Spell, IsPlayerSpell = savedSpell, savedKnown
    -- Cooldown just started with the player at the step: played, not passed.
    FG.Routes["hearth-test"].steps[1].m, FG.Routes["hearth-test"].steps[1].x, FG.Routes["hearth-test"].steps[1].y =
        1426, 30.1, 71.3
    cd = { GetTime() - 5, 3600 }
    useRoute("hearth-test")
    local done, passed = FG.Guide:IsDone(FG.Guide:Route().steps[1], 1)
    assert(done and not passed, "hearth just used and arrived: done and played")
    FG.Routes["hearth-test"].steps[1].m, FG.Routes["hearth-test"].steps[1].x, FG.Routes["hearth-test"].steps[1].y =
        nil, nil, nil
    -- Cooldown just started, player not at the step: neither done nor passed; past the window: passed.
    a, b = probe(GetTime() - 5, 3600)
    assert(not a and not b, "hearth just used, not arrived: neither done nor passed")
    local steps1 = FG.Guide:Route().steps
    local d1, p1 = FG.Guide:IsDone(steps1[1], 1)
    assert(not d1 and not p1, "hearth just used, not arrived: not done, not passed")
    a, b = probe(GetTime() - 120, 3600)
    assert(a and b, "cooldown past the just-used window: passed")
    -- Astral Recall on a client with only the global GetSpellCooldown, on its global cooldown: ready.
    local savedSpell2, savedKnown2, savedGlobal = C_Spell, IsPlayerSpell, GetSpellCooldown
    C_Spell = nil
    IsPlayerSpell = function(id) return id == 556 end
    GetSpellCooldown = function() return GetTime() - 1, 1.5 end
    a, b = probe(GetTime() - 120, 3600)
    assert(not a and not b, "global GetSpellCooldown, recall on global cooldown: steps stay")
    C_Spell, IsPlayerSpell, GetSpellCooldown = savedSpell2, savedKnown2, savedGlobal
    C_Container = {}
    a, b = probe(0, 0)
    assert(not a and not b, "no hearthstone info: no error, steps stay")
    C_Container = saved
    useRoute("fly-test")
    print("hearth cooldown ok")
end

-- Teleport: done once the character is there (around the city's class trainer).
FG.Routes["teleport-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1,
    steps = {
        { k = "teleport", t = "Teleport to Ironforge", m = 1426, x = 80, y = 20, lvl = 20 },
        { k = "teleport", t = "Teleport to Ironforge", m = 1426, x = 30.1, y = 71.3, lvl = 20 },
        { k = "grind", t = "Grind", lvl = 60 },
    },
}
useRoute("teleport-test")
fire("QUEST_LOG_UPDATE")
runTimers()
assert(char.guide.step == 1, "far from it: not there yet, step " .. char.guide.step)
char.guide.step = 2
fire("QUEST_LOG_UPDATE")
runTimers()
assert(char.guide.step == 3, "arrived, step " .. char.guide.step)
print("teleport ok")

-- Built-in guides (Builtin\*.lua): the character's variant of each, with its steps only; a "goto"
-- step done once there, a "note" once marked.
do
    local routes, info = FG.Routes, FG.Import.info
    FG.Builtin.Register({
        name = "builtin-test",
        origin = "test",
        fromLevel = 1,
        toLevel = 60,
        locale = "enUS",
        version = 1,
        format = 2,
        created = 1,
        variants = { { race = 1, class = 1, faction = "Alliance" }, { race = 7, class = 8, faction = "Alliance" } },
        steps = {
            { k = "goto", t = "Here", m = 1426, x = 30.1, y = 71.3, lvl = 20 },
            { k = "note", t = "Humans only", only = { 1 }, lvl = 20 },
            { k = "note", t = "Read this", only = { 2 }, lvl = 20 },
            { k = "goto", t = "Far away", m = 1426, x = 80, y = 20, r = 15, lvl = 20 },
            { k = "grind", t = "Grind", lvl = 60 },
        },
    })
    FG.Import:Apply()
    -- The guides the tests before put in FG.Routes themselves.
    for name, r in pairs(routes) do
        FG.Routes[name] = FG.Routes[name] or r
    end
    local r = FG.Routes["builtin-test"]
    assert(r and r.builtin and r.race == 7 and r.class == 8 and #r.steps == 4, "the gnome mage's variant")
    assert(r.steps[2].t == "Read this" and r.steps[2].only == nil, "its own steps only")
    assert(FG.Import.info["builtin-test"].source == "builtin", "a built-in guide")
    local listed
    for _, g in ipairs(FG.Import:List()) do
        if g.name == "builtin-test" then listed = g end
    end
    assert(listed and listed.fits and listed.source == "builtin", "listed for the character")
    -- Tabs: the guide followed is one; following another opens a tab beside it.
    local before = FG.Guide:RouteName()
    char.guide.tabs = nil -- the guides of the tests before
    FG.Guide:Refresh()
    assert(FG.Guide:Tabs()[1] == before, "the guide followed has a tab")
    useRoute("builtin-test")
    local tabs = FG.Guide:Tabs()
    assert(#tabs == 2 and tabs[1] == before and tabs[2] == "builtin-test", "a second tab")
    -- The guide browser: the guides by source, one picked and opened.
    FG.GuideBrowser:Toggle()
    assert(FG.GuideBrowser:IsShown(), "the browser opens")
    FG.GuideBrowser.picked = "builtin-test"
    FG.GuideBrowser:Fill()
    assert(FG.GuideBrowser.picked == "builtin-test", "the current guide's section opens first")
    FG.GuideBrowser:Toggle()
    assert(not FG.GuideBrowser:IsShown(), "and closes")
    fire("QUEST_LOG_UPDATE")
    runTimers()
    assert(char.guide.step == 2, "there; the note waits, step " .. char.guide.step)
    FG.Guide:ToggleSkip(2)
    fire("QUEST_LOG_UPDATE")
    runTimers()
    assert(char.guide.step == 3, "the note marked; far from the next place, step " .. char.guide.step)
    -- Back to the first tab and again: each guide where it was left.
    FG.Guide:Choose(before)
    FG.Guide:Choose("builtin-test")
    assert(char.guide.step == 3, "progress kept per tab, step " .. char.guide.step)
    -- Closing the tab followed follows the one beside it.
    FG.Guide:CloseTab("builtin-test")
    assert(FG.Guide:RouteName() == before and #FG.Guide:Tabs() == 1, "tab closed")
    -- A finished guide naming the one after it: that one opens in a tab, once.
    FG.Builtin.Register({
        name = "builtin-first",
        next = "builtin-test",
        variants = { { race = 7, class = 8, faction = "Alliance" } },
        steps = { { k = "note", t = "Read this", lvl = 1 } },
    })
    FG.Import:Apply()
    for name, r in pairs(routes) do
        FG.Routes[name] = FG.Routes[name] or r
    end
    assert(FG.Routes["builtin-first"].next == "builtin-test", "next passed on")
    FG.Guide:Choose("builtin-first")
    FG.Guide:ToggleSkip(1)
    fire("QUEST_LOG_UPDATE")
    runTimers()
    assert(FG.Guide:RouteName() == "builtin-test", "the next guide opened: " .. tostring(FG.Guide:RouteName()))
    FG.Guide:Choose("builtin-first")
    assert(FG.Guide:RouteName() == "builtin-first", "back to the finished guide, it stays")
    FG.Guide:CloseTab("builtin-first")
    table.remove(FG.Builtin.defs)
    -- A guide made for other characters: offered with the variant closest to this one.
    FG.Builtin.Register({
        name = "builtin-other",
        variants = { { race = 2, class = 1, faction = "Horde" }, { race = 1, class = 8, faction = "Alliance" } },
        steps = { { k = "note", t = "Hi", lvl = 1 } },
    })
    FG.Import:Apply()
    local other = FG.Routes["builtin-other"]
    assert(other and other.race == 1 and other.class == 8 and not FG.Import.Fits(other), "closest variant offered")
    -- A guide both factions play: the next guide of the variant's faction.
    FG.Builtin.Register({
        name = "builtin-both",
        next = { Horde = "builtin-horde", Alliance = "builtin-alliance" },
        variants = { { race = 7, class = 8, faction = "Alliance" }, { race = 2, class = 1, faction = "Horde" } },
        steps = { { k = "note", t = "Hi", lvl = 1 } },
    })
    local def = FG.Builtin.defs[#FG.Builtin.defs]
    assert(FG.Builtin.Expand(def, 1).next == "builtin-alliance", "Alliance next")
    assert(FG.Builtin.Expand(def, 2).next == "builtin-horde", "Horde next")
    table.remove(FG.Builtin.defs)
    table.remove(FG.Builtin.defs)
    table.remove(FG.Builtin.defs)
    FG.Routes, FG.Import.info = routes, info
    -- The walks: one for every variant (`wp`), another for some (`wv`), none for some.
    local walks = {
        variants = {
            { race = 2, class = 1, faction = "Horde" },
            { race = 2, class = 3, faction = "Horde" },
            { race = 8, class = 5, faction = "Horde" },
        },
        steps = {
            { k = "goto", t = "Shared", m = 1411, x = 40, y = 60, lvl = 1, wp = { 1, 2, 3, 4 } },
            {
                k = "goto",
                t = "Per variant",
                m = 1411,
                x = 45,
                y = 65,
                lvl = 1,
                wp = { 5, 6 },
                wv = { { { 2 }, { 7, 8, 9, 10 } }, { { 3 }, {} } },
            },
            {
                k = "goto",
                t = "Some",
                m = 1411,
                x = 50,
                y = 70,
                lvl = 1,
                only = { 1, 3 },
                wv = { { { 3 }, { 11, 12 } } },
            },
            { k = "note", t = "None", lvl = 1 },
        },
    }
    local function wp(index, n)
        local s = FG.Builtin.Expand(walks, index).steps[n]
        assert(s.wv == nil and s.only == nil, "no wv nor only in the route")
        return s.wp and table.concat(s.wp, ",") or "none"
    end
    assert(wp(1, 1) == "1,2,3,4" and wp(2, 1) == "1,2,3,4" and wp(3, 1) == "1,2,3,4", "a walk for all")
    assert(wp(1, 2) == "5,6" and wp(2, 2) == "7,8,9,10" and wp(3, 2) == "none", "a walk per variant")
    assert(
        wp(1, 3) == "none" and wp(2, 3) == "none" and #FG.Builtin.Expand(walks, 2).steps == 3,
        "variant 2: no step 3"
    )
    assert(wp(3, 3) == "11,12" and wp(3, 4) == "none", "the variant's own walk, none")
    assert(walks.steps[2].wp[1] == 5 and walks.steps[2].wv, "the def unchanged")
    print("builtin ok")
end

-- The guides shipped (Builtin\*.lua): each one registers, and each of its variants is a route
-- whose steps are of a kind the guide knows, with a place, and hand in only quests taken before.
do
    local before = #FG.Builtin.defs
    local list = io.popen("ls addon/Pathwright_Guide/Builtin")
    for name in list:lines() do
        if name:match("%.lua$") then assert(loadfile("addon/Pathwright_Guide/Builtin/" .. name))() end
    end
    list:close()
    local kinds = {
        accept = true,
        turnin = true,
        objective = true,
        train = true,
        sell = true,
        bind = true,
        grind = true,
        note = true,
        ["goto"] = true,
        flight_master = true,
        fly = true,
        hearth = true,
    }
    -- Walks (guide_build.py): every guide has some.
    local wantWalks = true
    local count, walked = 0, 0
    for i = before + 1, #FG.Builtin.defs do
        local def = FG.Builtin.defs[i]
        local walks = 0
        for v = 1, #def.variants do
            local r = FG.Builtin.Expand(def, v)
            assert(r.race and r.class and r.faction and #r.steps > 0, def.name .. ": variant " .. v)
            local taken = {}
            for _, q in ipairs(def.carry or {}) do
                taken[q] = true
            end
            for n, s in ipairs(r.steps) do
                local where = def.name .. " variant " .. v .. " step " .. n
                assert(kinds[s.k], where .. ": kind " .. tostring(s.k))
                assert(s.t and s.lvl, where .. ": text and level")
                assert(s.k == "grind" or s.k == "note" or (s.m and s.x and s.y), where .. ": place")
                assert(s.wv == nil, where .. ": wv resolved")
                if s.wp then
                    assert(#s.wp >= 2 and #s.wp % 2 == 0 and not s.bg, where .. ": walk")
                    walks = walks + 1
                end
                if s.k == "accept" then taken[s.q] = true end
                -- An item to buy at the auction house may come before its quest is taken.
                if s.k == "turnin" or (s.k == "objective" and not s.by) then
                    assert(taken[s.q], where .. ": quest not taken")
                end
            end
            count = count + 1
        end
        assert(walks > 0 or not wantWalks, def.name .. ": no walk")
        if walks > 0 then walked = walked + 1 end
    end
    for _ = before + 1, #FG.Builtin.defs do
        table.remove(FG.Builtin.defs)
    end
    print("shipped guides ok: " .. count .. " routes, " .. walked .. " guides with walks")
end

-- Quest stats (Stats.lua): a quest's time runs from the fight of its first kill to its last
-- count, only in its area, each kill's time going to its own quest; how each unit of an item
-- was got; the score worked out from a record's facts; sealed records shared with friends.
do
    local S = FG.Stats
    local realWhere, realFacts = S.where, S.ItemFacts
    local realData = FG.StatsData
    FG.StatsData = { escort = "|950|", quests = { [901] = "500;1;5", [902] = "0;1;" } }
    S.dataCache = {}
    local clockNow, wallNow, at = 1000, 1800000000, { 0, 100, 100 }
    S.clock, S.now = function() return clockNow end, function() return wallNow end
    S.where = function() return at[1], at[2], at[3] end
    S.ItemFacts = function(name) return name == "Bear Ass" and 4002 or nil, false end
    local realLevel = playerLevel
    playerLevel = 10
    local quests = S:Quests()
    for id in pairs(quests) do
        quests[id] = nil
    end
    local spare = S:Spare()
    for id in pairs(spare) do
        spare[id] = nil
    end
    local function Log(kills, claws, more)
        local log = {
            [900] = {
                level = 10,
                { have = kills, need = 3, type = "monster", text = "Kobold slain: " .. kills .. "/3" },
            },
            [901] = { level = 10, { have = claws, need = 2, type = "item", text = "Wolf Claw: " .. claws .. "/2" } },
        }
        for id, entry in pairs(more or {}) do
            log[id] = entry
        end
        return log
    end
    S:Apply(Log(0, 0), true)
    S:Tick()
    assert(_G.next(quests) == nil, "nothing under way yet")
    -- The clock starts with the fight of the first kill.
    S:Fight(true, 77)
    clockNow = clockNow + 8
    S:Kill(77, "kobold-1")
    S:Fight(false)
    S:Apply(Log(1, 0))
    local rec = quests[900]
    assert(rec and rec.v == 2 and rec.s == wallNow and rec.t == 8, "the first kill's fight is its time")
    assert(rec.mobs and rec.mobs[77], "the mob its objective counts is remembered")
    clockNow = clockNow + 5
    S:Tick()
    assert(rec.t == 8 and S.pend[900] == 5, "in its area: waiting for its next count")
    S:Apply(Log(2, 0))
    assert(rec.t == 13 and S.pend[900] == nil, "the count takes the time since the last one")
    at = { 0, 2000, 2000 } -- a hearth to town
    clockNow = clockNow + 5
    S:Tick()
    assert(S.pend[900] == nil, "away from its area: not counted")
    clockNow = clockNow + 3600 -- logged out
    at = { 0, 120, 90 }
    S:Tick()
    assert(S.pend[900] == 10, "a long gap counts 10 s at most")
    -- An item quest starts at the first kill of a mob that drops its item, not at its first drop;
    -- the time waiting goes to the quest of that kill, not to the kobolds'.
    S:Fight(true, 5)
    clockNow = clockNow + 6
    S:Kill(5, "wolf-1")
    S:Fight(false)
    local wolf = quests[901]
    assert(wolf and wolf.s == wallNow and wolf.t == 6 and wolf.ki == 1, "started by the kill of a mob that drops it")
    assert(S.pend[900] == nil, "the time before a kill is its quest's alone")
    -- Loot: the units dropped, the mobs killed (a kill and its corpse are one), what no quest
    -- wants kept as looted.
    S:Loot({
        { npc = 5, guid = "wolf-1", items = { ["wolf claw"] = 1 }, ids = { ["wolf claw"] = 4001 } },
        { npc = 5, guid = "wolf-2", items = {} },
        { npc = 7, guid = "bear-1", items = { ["bear ass"] = 2 }, ids = { ["bear ass"] = 4002 } },
    })
    assert(wolf.ki == 2 and wolf.dr == 1 and wolf.got["wolf claw"] == 1, "kills and drops of its mobs")
    assert(S.Rate(wolf, "wolf claw") == 0.5, "drop rate of the corpses of its mobs")
    assert(spare[4002] == 2 and not spare[4001], "what no quest wants yet is kept as looted")
    S:Apply(Log(2, 1))
    -- A death: on the quest of the mob fought.
    S:Fight(true, 77)
    assert(S:Died() == 900 and rec.de == 1 and not wolf.de, "a death counts on the quest of the mob fought")
    S:Fight(false)
    -- Objectives complete: the clock stops, the score shows; nothing is sent before the hand-in.
    local sent = {}
    local realChat, realFriends = C_ChatInfo, C_FriendList
    C_ChatInfo = {
        SendAddonMessage = function(prefix, text, channel, target)
            table.insert(sent, { prefix = prefix, text = text, channel = channel, target = target })
        end,
    }
    C_FriendList = {
        GetNumFriends = function() return 2 end,
        GetFriendInfoByIndex = function(i)
            return i == 1 and { name = "Ally", connected = true } or { name = "Old", connected = true }
        end,
    }
    S.Forget(true)
    local function drain()
        for _ = 1, 100 do
            runTimers()
        end
    end
    clockNow = clockNow + 5
    S:Tick()
    S:Apply(Log(3, 1))
    assert(rec.e == wallNow and rec.t == 18 and rec.k == 3 and rec.lv == 10 and rec.pl == 10, "complete: its facts")
    assert(#sent == 0 and not rec.d, "not final before it is handed in")
    local line = S:StepLine({ k = "objective", q = 900 })
    assert(line and line:find("0:18", 1, true) and line:find(" pts", 1, true), tostring(line))
    local claw = S:StepLine({ k = "objective", q = 901, e = "item", n = "Wolf Claw" })
    assert(claw and claw:find("50%", 1, true), tostring(claw))
    -- Handed in: only its facts stay, sealed, and go to the friends.
    S:TurnedIn(900)
    drain()
    assert(rec.d == wallNow and rec.seal and not rec.area and not rec.mobs, "handed in: final, only its facts kept")
    local q = sent[1]
    assert(q and q.prefix == "PWStats" and q.channel == "WHISPER" and q.target:find("^Ally%-"), "to online friends")
    local f, seal, wire = S.Parse(q.text:sub(3))
    assert(f and f.q == 900 and f.k == 3 and f.t == 18 and f.de == 1, q.text)
    assert(
        seal == rec.seal and seal == S.Seal(wire, "Brouz") and S.Plausible(f, wallNow),
        "sealed with the character's name"
    )
    local total, count, records, mark = S:Total()
    -- 40 + 3, speed 150 at most (par 60 s in 18 s), one death: 178.
    assert(total == 178 and count == 1 and records == 1 and mark == tonumber(seal, 16), "my total: " .. total)

    -- The score, from a record's facts.
    local function pts(facts, rate, drops)
        facts.lv, facts.pl = facts.lv or 10, facts.pl or 10
        return S.Points(facts, rate, drops)
    end
    assert(pts({ k = 8, t = 160 }) == 108, "40 + 8 + 60 at par")
    assert(pts({ k = 8, t = 80 }) == 168, "twice as fast")
    assert(pts({ k = 8, t = 160, de = 1 }) == 93, "a death costs 15")
    assert(pts({ k = 8, t = 160, lv = 13 }) == 135, "an orange quest: x 1.25")
    assert(pts({ k = 8, t = 160, lv = 15 }) == 162, "a red quest: x 1.5")
    assert(pts({ k = 8, t = 160, lv = 7 }) == 81, "a green quest: x 0.75")
    assert(pts({ k = 8, t = 160, lv = 4 }) == 54, "a gray quest: x 0.5")
    assert(pts({ it = 10, on = 10, ki = 20, dr = 10, t = 400 }, 0.5) == 110, "items farmed at par, average luck")
    assert(pts({ it = 10, on = 10, ki = 20, dr = 10, t = 400 }, 0.25) == 150, "half the kills expected: + 40")
    assert(pts({ it = 10, on = 10, ki = 100, dr = 10, t = 2000 }, 0.25) == 70, "bad luck: - 40 at most")
    assert(pts({ it = 10, on = 10, ki = 20, dr = 10, t = 400 }) == 110, "no rate known: no luck")
    assert(pts({ it = 10, ob = 10 }) == 25, "all bought, of an item that drops: half the base")
    assert(pts({ it = 10, ou = 10 }) == 50, "an item nothing drops: the base")
    assert(pts({ it = 10, ou = 10 }, nil, true) == 25, "seen to drop since: bought")
    assert(pts({ it = 10, ea = 10 }) == 50, "looted before the quest: the base, no speed")
    assert(pts({ it = 10, on = 1, ob = 9, ki = 2, dr = 1, t = 10 }) == 43, "9 of 10 bought: a tenth of the speed")
    assert(pts({ x = 1 }) == 100 and pts({ x = 1, de = 1, f = 1 }) == 70, "an escort: flat, less deaths and failures")
    assert(pts({ x = 1, lv = 15 }) == 150, "an escort takes the color too")
    assert(S.Color(15, 10) == 1 and S.Color(13, 10) == 2 and S.Color(8, 10) == 3, "red, orange, yellow")
    assert(S.Color(7, 10) == 4 and S.Color(4, 10) == 5 and S.Color(0, 10) == 3, "green, gray, unknown")
    assert(S.Color(48, 60) == 5 and S.Color(52, 60) == 4, "gray and green at 60")

    -- Bought or farmed: 3 Bear Ass asked, 2 looted before the quest, 1 got otherwise.
    local bear = { level = 10, { have = 3, need = 3, type = "item", text = "Bear Ass: 3/3" } }
    S:Apply(Log(3, 1, { [902] = bear }))
    local b = quests[902]
    assert(b and b.e and b.it == 3 and b.on == 0 and b.ea == 2 and b.ob == 1, "looted earlier, and bought")
    assert(spare[4002] == nil, "the units looted earlier are used")
    assert(S:Score(b, 902) == 36, "(40 + 3) x (1 - 0.5 / 3): " .. S:Score(b, 902))

    -- Abandoned and taken again: the same record goes on.
    local function Rats(n) return { level = 10, { have = n, need = 2, type = "monster", text = "Rat: " .. n .. "/2" } } end
    S:Apply(Log(3, 1, { [903] = Rats(0) }))
    S:Fight(true, 80)
    clockNow = clockNow + 4
    S:Fight(false)
    S:Apply(Log(3, 1, { [903] = Rats(1) }))
    assert(quests[903].t == 4, "its first kill")
    S:Apply(Log(3, 1)) -- abandoned
    assert(quests[903] and quests[903].t == 4 and not quests[903].e, "abandoned: its record is kept")
    S:Apply(Log(3, 1, { [903] = Rats(0) }))
    clockNow = clockNow + 7
    S:Tick()
    S:Apply(Log(3, 1, { [903] = Rats(1) }))
    assert(quests[903].t == 11, "taken again: its time adds up")

    -- An escort: taken, a death, a failure, complete, handed in: flat.
    local function Escort(state)
        return Log(
            3,
            1,
            { [903] = Rats(1), [950] = { level = 10, complete = state == "done", failed = state == "failed" } }
        )
    end
    S:Apply(Escort())
    local escort = quests[950]
    assert(escort and escort.x == 1 and escort.s == wallNow, "an escort in the log")
    S:Fight(true, 4242)
    assert(S:Died() == 950 and escort.de == 1, "a death during an escort is its own")
    S:Apply(Escort("failed"))
    S:Apply(Escort("failed"))
    assert(escort.f == 1, "a failed attempt, counted once")
    S:Apply(Escort("done"))
    assert(escort.e == wallNow, "complete")
    sent = {}
    completed[950] = true
    S:Apply(Log(3, 1, { [903] = Rats(1) })) -- gone from the log, flagged complete: handed in
    drain()
    completed[950] = nil
    assert(escort.d and S:Score(escort, 950, true) == 70, "100 - 15 - 15")
    assert(sent[1] and sent[1].text:find("^F|950,"), "the escort's record is sent")

    -- Friends' records: from friends only, sealed with their name, the first one kept.
    local friend, old = sent[1].target, sent[1].target:gsub("^Ally", "Old")
    local theirs = S.Wire(900, { d = wallNow - 10, t = 60, lv = 10, pl = 10, k = 3 })
    local theirSeal = S.Seal(theirs, "Ally")
    sent = {}
    S:Receive("H|2|9999|1|" .. tonumber(theirSeal, 16) .. "|1|0|0", friend)
    drain()
    local askedFor
    for _, m in ipairs(sent) do
        if m.text == "S|0" and m.target == friend then askedFor = true end
    end
    assert(askedFor, "their records are asked for")
    S:Receive("F|" .. theirs .. "," .. theirSeal, friend)
    S:Receive("H|2|9999|1|1|1|0|0", "Stranger-Realm")
    S:Receive("H|1|500|1", old)
    S:Receive("Q|900|12|60|130|49000", old)
    local board = S:Standings()
    local byName = {}
    for _, e in ipairs(board) do
        byName[e.name] = e
    end
    assert(#board == 3 and not byName.Stranger, "the leaderboard: friends only")
    assert(byName.Ally.total == 103 and byName.Ally.count == 1, "a friend's total is worked out from their records")
    assert(byName.Old.total == 500, "a friend with the older addon: as they say")
    local tip = S:TooltipLines({ q = 900 })
    assert(
        tip and table.concat(tip, "\n"):find("Ally", 1, true) and table.concat(tip, "\n"):find("103", 1, true),
        "friends in the tooltip"
    )
    -- A record edited (its seal no longer its own), an impossible one, a second one for the quest.
    local peer = PathwrightDB.stats.peers[friend]
    S:Receive("F|" .. theirs:gsub(",60,", ",6,", 1) .. "," .. theirSeal, friend)
    assert(peer.refused == 1 and not peer.flag, "a record that does not match its seal is refused")
    local fast = S.Wire(905, { d = wallNow - 5, t = 2, lv = 10, pl = 10, k = 30 })
    S:Receive("F|" .. fast .. "," .. S.Seal(fast, "Ally"), friend)
    assert(peer.refused == 2 and not peer.q[905], "30 kills in 2 s cannot be")
    local again = S.Wire(900, { d = wallNow - 10, t = 20, lv = 10, pl = 10, k = 3 })
    S:Receive("F|" .. again .. "," .. S.Seal(again, "Ally"), friend)
    assert(
        peer.flag and peer.q[900] == theirs .. "," .. theirSeal,
        "the first record of a quest stays, the player is marked"
    )
    peer.flag = nil
    -- A request: a page of our records, oldest first, then its end.
    sent = {}
    S:Receive("S|0", friend)
    drain()
    assert(
        sent[1].text:find("^F|9%d%d,") and sent[1].text:find(";", 1, true),
        "records sent by the page: " .. sent[1].text
    )
    assert(sent[#sent].text == "E|0|" .. wallNow, "then the end of the page: " .. sent[#sent].text)
    sent = {}
    S:Receive("R|0", old)
    drain()
    assert(sent[1] and sent[1].text:find("^Q|9%d%d|"), "the older addon is still answered")
    -- An item nothing is known to drop: the kills of a mob count from its first one, once it
    -- has dropped the item.
    local function Hides(n)
        return { level = 10, { have = n, need = 2, type = "item", text = "Odd Hide: " .. n .. "/2" } }
    end
    S:Apply(Log(3, 1, { [903] = Rats(1), [904] = Hides(0) }))
    S:Fight(true, 60)
    clockNow = clockNow + 9
    S:Kill(60, "odd-1")
    S:Fight(false)
    local odd = quests[904]
    assert(odd and not odd.s and odd.pre[60].n == 1 and odd.pre[60].t == 9, "a mob that may drop it is remembered")
    clockNow = clockNow + 5
    S:Tick()
    S:Kill(60, "odd-2")
    S:Loot({ { npc = 60, guid = "odd-2", items = { ["odd hide"] = 1 }, ids = { ["odd hide"] = 4004 } } })
    assert(
        odd.s == wallNow and odd.t == 14 and odd.ki == 2 and odd.dr == 1 and not odd.pre,
        "its clock from the first kill"
    )
    assert(odd.src[60], "the mob is one of its own from now on")
    -- The guild: a hello on its channel is taken from any member, ours coming back is not.
    local realInGuild, realMembers, realRoster = IsInGuild, GetNumGuildMembers, GetGuildRosterInfo
    IsInGuild, GetNumGuildMembers = function() return true end, function() return 1 end
    GetGuildRosterInfo = function() return "Gil" end
    S.Forget(true)
    local gil = friend:gsub("^Ally", "Gil")
    S:Receive("H|2|77|0|0|0|77|3", gil, nil, "GUILD")
    S:Receive("H|2|5|0|0|0|5|1", friend:gsub("^Ally", "Brouz"), nil, "GUILD")
    assert(PathwrightDB.stats.peers[gil].lt == 77 and #S:Standings() == 4, "a guild member is on the board")
    S:Receive("H|2|999|0|0|0|999|9", gil, nil, "GUILD")
    assert(select(1, S:PeerTotal(PathwrightDB.stats.peers[gil])) == 77, "what they scored before: as first said")
    sent = {}
    S:Hello()
    drain()
    local toGuild
    for _, m in ipairs(sent) do
        toGuild = toGuild or m.channel == "GUILD"
    end
    assert(toGuild, "our hello goes to the guild")
    -- Fingerprints above the signed limit must reach peers as the original decimal digits.
    do
        local total, record = S.Total, peer.q[900]
        S.Total = function() return 2033, 25, 7, 2436634204, 1403, 18 end
        peer.q[900] = theirs .. ",ffffffff"
        sent = {}
        S:Hello(friend)
        S:HelloAll()
        drain()
        S.Total, peer.q[900] = total, record
        local hello, comparison
        for _, m in ipairs(sent) do
            if m.target == friend and m.text:find("^H|2|2033|25|2436634204|7|1403|18|") then hello = true end
            if m.target == old and m.text == "P|" .. friend .. "|1|4294967295" then comparison = true end
        end
        assert(hello and comparison, "unsigned fingerprints in both stats messages")
    end
    -- Two friends of a player compare what they hold of them.
    S:Receive("P|" .. friend .. "|1|12345", old)
    assert(peer.flag, "as many records, not the same: the player is marked")
    peer.flag = nil
    IsInGuild, GetNumGuildMembers, GetGuildRosterInfo = realInGuild, realMembers, realRoster
    -- A player's name in a seal: the same on both sides, whatever form the game gives it. On WoW
    -- Forever a character's own game names it by its first word ("Kel" for "Kel Wick"), and a
    -- sender's name loses its space on the way.
    local function sealed(quest, name)
        local wire = S.Wire(quest, { d = wallNow - 20, t = 60, lv = 10, pl = 10, k = 3 })
        return "F|" .. wire .. "," .. S.Seal(wire, name)
    end
    -- A seal at or above 2^31 (half of them): the game's string.format raises on such a value.
    do
        local format = string.format
        string.format = function(pattern, ...)
            for i = 1, select("#", ...) do
                local v = select(i, ...)
                if pattern:find("%%[%d.]*[xd]") and type(v) == "number" and (v < -2147483648 or v > 2147483647) then
                    error("integer overflow attempting to store " .. format("%.0f", v))
                end
            end
            return format(pattern, ...)
        end
        local ok, err = pcall(function()
            local quest, wire, seal
            for q = 1100, 1200 do
                wire = S.Wire(q, { d = wallNow - 20, t = 60, lv = 10, pl = 10, k = 3 })
                seal = S.Seal(wire, "Ally")
                if tonumber(seal, 16) >= 2147483648 then
                    quest = q
                    break
                end
            end
            assert(quest, "a seal with the top bit set")
            assert(#seal == 8 and seal:match("^%x+$"), "eight hex digits")
            S:Receive("F|" .. wire .. "," .. seal, friend)
            assert(peer.q[quest], "the record with a high seal is accepted")
            peer.q[quest], S.shared = nil, nil -- not a quest of the board's tally below
        end)
        string.format = format
        assert(ok, tostring(err))
        -- Pinned from the old string.format("%08x", Hash(...)) seal, computed with 32-bit FNV-1a.
        assert(S.Seal("w1", "y") == "2e4eebe9", "seal below 2^31 unchanged")
        assert(S.Seal("w199", "y") == "000607ff", "seal keeps its zero padding")
        assert(S.Seal("x", "y") == "a79e930f", "seal at or above 2^31 unchanged")
        assert(S.Seal("a", "b") == "daeebe19", "high half stays first")
    end
    local refusedBefore = peer.refused
    S:Receive(sealed(911, "Ally"), friend, nil, nil, "Ally Wick")
    S:Receive(sealed(912, "AllyWick"), friend, nil, nil, "Ally Wick")
    S:Receive(sealed(913, "Ally Wick"), friend, nil, nil, "Ally Wick-Realm")
    assert(
        peer.q[911] and peer.q[912] and peer.q[913] and peer.refused == refusedBefore,
        "sealed with any form of their name"
    )
    S:Receive(sealed(914, "Wick"), friend, nil, nil, "Ally Wick")
    assert(not peer.q[914] and peer.refused == refusedBefore + 1, "but not with another name")
    assert(table.concat(S.SealNames("Kel Wick-Realm"), "|") == "KelWick|Kel|Kel Wick", "the names a seal may bear")
    -- Our own hello back from the guild's channel, under our whole name: not a friend.
    local echo = friend:gsub("^Ally", "BrouzTwo")
    S:Receive("H|2|5|1|1|1|0|0", echo, nil, "GUILD", "Brouz Two")
    assert(not PathwrightDB.stats.peers[echo] and PathwrightDB.stats.own[echo], "our own message is no friend's")
    -- At login: friends an older version refused records of are asked for them again.
    peer.cursor = 99
    S:Verify()
    assert(peer.refused == nil and peer.cursor == 0, "refused records are asked for again")
    peer.q[911], peer.q[912], peer.q[913], S.shared = nil, nil, nil, nil
    -- A record of mine edited by hand: left out.
    rec.k = 99
    S:Verify()
    assert(rec.bad and select(3, S:Total()) == 1, "an edited record no longer matches its seal")
    -- The board: each player with what their average quest is made of, their latest quests in
    -- the detail a click opens, more or fewer rows as the window is dragged taller.
    local mine, ally
    for _, e in ipairs(S:Standings()) do
        if e.me then mine = e end
        if e.full == friend then ally = e end
    end
    assert(
        mine.total == 70 and mine.records == 1 and mine.parts.base == 100 and mine.parts.lost == 30,
        "my escort's parts"
    )
    assert(
        ally.total == 103 and ally.parts.base == 43 and ally.parts.speed == 60 and ally.colors[3] == 1,
        "a friend's parts"
    )
    local history = S:History(ally)
    assert(#history == 1 and history[1].q == 900 and history[1].pts == 103 and history[1].t == 60, "a friend's quests")
    assert(S:History(mine)[1].escort and S:History(mine)[1].pts == 70, "my quests: the escort")
    S:ToggleBoard()
    local board = S.board
    assert(board:IsShown() and board.pane.content:IsShown() and S.selected == "me", "the board opens on you")
    board.rows[1]:GetScript("OnClick")(board.rows[1])
    assert(S.selected == board.rows[1].full and S.selected ~= "me", "a click on a player shows their detail")
    board.rows[1]:GetScript("OnClick")(board.rows[1])
    assert(S.selected == board.rows[1].full and board.pane.content:IsShown(), "the detail stays open")
    PathwrightDB.stats.boardRows, PathwrightDB.stats.boardList, PathwrightDB.stats.boardPane = 5, 600, 100
    S:FillBoard()
    assert(not (board.rows[6] and board.rows[6]:IsShown()), "fewer rows when the window is made shorter")
    assert(board.barWidth == 600 - 308 - 32 and board.pane.bar.width == 70, "a wider list, the narrowest detail")
    board.tabs.guild:GetScript("OnClick")(board.tabs.guild)
    assert(
        S.scope == "guild" and board.rows[2]:IsShown() and not board.rows[3]:IsShown(),
        "the guild's tab: its members"
    )
    assert(S.selected == "me", "a tab opens on you too")
    S.scope = nil
    S:ToggleBoard()
    C_ChatInfo, C_FriendList = realChat, realFriends
    S.Forget(true)
    PathwrightDB.stats = nil
    for id in pairs(quests) do
        quests[id] = nil
    end
    for id in pairs(spare) do
        spare[id] = nil
    end
    FG.StatsData, S.dataCache = realData, {}
    playerLevel = realLevel
    S.clock, S.now, S.where, S.ItemFacts = GetTime, time, realWhere, realFacts
    print("quest stats ok")
end

-- A character's key (Core.lua): its own on WoW Forever, where the characters of an account share
-- the name the game gives them; what they shared before goes to the one it was last used by.
do
    local key, realm = FG.CharacterKeyOf("Weirdman", "", "Player-6923-0001C1EB")
    assert(key == "Weirdman-#6923-0001C1EB" and realm == "#6923-0001C1EB", "a character's own key: " .. key)
    assert(
        FG.CharacterKeyOf("Weirdman", nil, "Player-6923-03BF5F88") ~= key,
        "another character of the name: another key"
    )
    assert(FG.CharacterKeyOf("Brouz", "Realm", "Player-1-2") == "Brouz-Realm", "a realm with a name: as before")
    assert(select(2, FG.CharacterKeyOf("Weirdman", "", nil)) == "", "not known yet without a realm or a GUID")
    local db = {
        characters = {
            ["Weirdman-#6923"] = { class = "SHAMAN", race = "Troll", guide = { route = "Feralas (45-46)" } },
            ["Weirdman-"] = { class = "WARLOCK", race = "Orc", guide = { route = "Riverglades (44-45)" } },
        },
        profiles = { ["Weirdman-#6923"] = { level = 46 } },
        sent = { ["Weirdman-#6923"] = 7 },
    }
    local druid, shaman, warlock = "Weirdman-#6923-AAAA", "Weirdman-#6923-BBBB", "Weirdman-#6923-CCCC"
    assert(
        FG.AdoptCharacter(db, druid, "Weirdman", "#6923-AAAA", "DRUID", "Tauren", 6) == nil,
        "the druid takes nobody's"
    )
    assert(db.characters[druid] == nil and db.characters["Weirdman-#6923"], "what was the shaman's stays for it")
    assert(
        FG.AdoptCharacter(db, shaman, "Weirdman", "#6923-BBBB", "SHAMAN", "Troll", 8) == "Weirdman-#6923",
        "the shaman's"
    )
    assert(
        db.characters[shaman].guide.route == "Feralas (45-46)" and not db.characters["Weirdman-#6923"],
        "moved to it"
    )
    assert(
        db.profiles[shaman].level == 46 and db.sent[shaman] == 7 and not db.sent["Weirdman-#6923"],
        "with its profile"
    )
    assert(
        FG.AdoptCharacter(db, warlock, "Weirdman", "#6923-CCCC", "WARLOCK", "Orc", 2) == "Weirdman-",
        "the warlock's"
    )
    assert(db.characters[warlock].guide.route == "Riverglades (44-45)", "each its own guide")
    assert(
        FG.AdoptCharacter(db, "Brouz-Realm", "Brouz", "Realm", "MAGE", "Gnome", 7) == nil,
        "nothing to do with a realm's name"
    )
    print("character keys ok")
end

-- Feedback (Feedback.lua): a report of what was typed and of the game then; left for the updater
-- in the saved variables; cut to fit one Discord message when pasted by hand.
do
    local F = FG.Feedback
    local report = F:Report("The wolves are not at the marker")
    assert(report.report == "pathwright-feedback" and report.what_went_wrong:find("wolves"), "the words typed")
    assert(report.char.level == playerLevel and report.char.faction == "Alliance", "the character, without its name")
    assert(not FG.JSON(report):find("Brouz", 1, true), "no character name in a report")
    assert(report.client.locale == "frFR" and report.addon.release == "dev", "the game and the addon")
    assert(type(report.quests) == "table" and report.place.map, "the quest log and the place")
    local guide = report.guide
    assert(
        guide and guide.name == FG.Guide:RouteName() and guide.step == FG.Guide:CurrentStep(),
        "the guide and its step"
    )
    assert(guide.of == #FG.Guide:Route().steps and guide.now and guide.now.i == guide.step, "the step itself")
    local text = F:Text("The wolves are not at the marker")
    assert(
        text:find("^Please open a GitHub issue from this report%.\n```json\n{") and text:find("\n```$"),
        text:sub(1, 80)
    )
    assert(#text <= 1900, "one Discord message: " .. #text)
    -- Too long to paste: the parts that say least go first, the words typed last.
    local big =
        { report = "pathwright-feedback", v = 1, what_went_wrong = string.rep("é", 250), quests = {}, errors = {} }
    for i = 1, 40 do
        big.quests[i] = { 90000 + i, 0, { { 3, 8 }, { 0, 12 }, { 1, 1 } } }
        big.errors[#big.errors + 1] = string.rep("x", 100)
    end
    big.guide = { name = "A guide", step = 3, of = 9, now = { i = 3, t = string.rep("t", 120) }, next = { { i = 4 } } }
    local cut = F.Fit(big)
    assert(#cut <= 1900 and big.cut and big.quests[1][3] == nil and not big.guide.next, "cut to fit: " .. #cut)
    assert(#F.Fit(big, 700) <= 700 and big.more_quests == 28 and #big.quests == 12, "then the quests beyond twelve")
    assert(cut:find("what_went_wrong", 1, true) and not cut:find("errors", 1, true), "the words stay, the errors go")
    assert(F.Cut("aéb", 2) == "a" and F.Cut("aéb", 3) == "aé", "never cut inside a character")
    assert(F.Base64("Man") == "TWFu" and F.Base64("Ma") == "TWE=" and F.Base64("M") == "TQ==", "base64")
    -- Left for the updater: a line it reads from the saved variables once the game has written them.
    PathwrightDB.feedback = nil
    local sent = F:Submit("  The wolves are not at the marker  ")
    assert(sent and sent:find("wolves", 1, true) and F.id, "OK makes the report")
    local line = PathwrightDB.feedback[1]
    local head = "PWFB1:" .. F.id .. ":"
    assert(#PathwrightDB.feedback == 1 and line:sub(1, #head) == head, "waiting for the updater: " .. line:sub(1, 40))
    assert(line:sub(#head + 1):find("^[%w%+/=]+$"), "the report in base64, nothing to escape")
    assert(F:Submit("  ") == nil and #PathwrightDB.feedback == 1, "nothing typed: no report")
    for _ = 1, 7 do
        F:Submit("again and again")
    end
    assert(#PathwrightDB.feedback == 5, "five reports wait at most")
    -- The updater's answer, read at login: the report it sent leaves the list.
    local first = PathwrightDB.feedback[1]:match("^PWFB1:([%w%-]+):")
    assert(not F.HasUpdater(), "no updater seen")
    FG.updater = { at = time(), sent = { [first] = "https://github.com/weirdr/Pathwright/issues/99" } }
    assert(F.HasUpdater(), "the updater ran here lately")
    F:Acknowledge()
    assert(#PathwrightDB.feedback == 4 and not PathwrightDB.feedback[1]:find(first, 1, true), "sent: off the list")
    -- The window: opened from its button under the guide, it stays open after OK.
    F:Toggle()
    assert(F.frame:IsShown() and not F.frame.reload:IsShown(), "the window, before OK")
    F:Submit("The wolves are not at the marker")
    assert(F.frame:IsShown() and F.frame.reload:IsShown() and F.text, "after OK: still open, a reload sends it")
    FG.updater = nil
    F:Submit("The wolves are not at the marker")
    assert(F.frame.reload:IsShown(), "no updater seen yet: the reload is offered all the same")
    F:Toggle()
    FG.updater, PathwrightDB.feedback = nil, nil
    print("feedback ok")
end

-- The party's progress for the guide's step lines (Party.lua): Pathwright members and Questie
-- players alike, at most 4, done ones flagged; Questie's whole-log message read.
do
    local P = FG.Party
    local saved = P.progress
    P.progress = {}
    P:Store("Zed", 900, { "3", "x" })
    P:Store("Amy", 900, { "8" })
    for _, n in ipairs({ "Bo", "Cy", "Di" }) do
        P:Store(n, 900, { "1" })
    end
    local m = P:Members(900, 1, 8)
    assert(#m == 4 and m[1].name == "Amy" and m[1].done and m[1].have == 8, "4 at most, by name, done flagged")
    assert(P:Members(900, 2, 5)[1].name == "Zed" and P:Members(900, 2, 5)[1].done, "a finished one")
    P:Forget("Zed", 900)
    assert(#P:Members(900, 2, 5) == 0, "forgotten once gone")
    -- A Questie player's whole log: { count, quest, n, (id, type, fulfilled, required) x n ... }.
    P.progress = {}
    local realParty = UnitInParty
    UnitInParty = function(name) return name == "Questy-Realm" end
    local QS = FG.QuestieShare
    local data =
        QS.Serialize({ ver = "1.0.0", msgVer = 5, msgId = 12, [1] = { 1, 900, 2, 0, 109, 3, 10, 0, 105, 2, 2 } })
    QS:Store(data, "Questy-Realm")
    local q = P.progress.Questy or P.progress["Questy-Realm"]
    assert(q and q[900] and q[900][1] == "3" and q[900][2] == "x", "Questie's counts kept")
    QS:Store(QS.Serialize({ ver = "1.0.0", msgVer = 5, msgId = 2, id = 900 }), "Questy-Realm")
    q = P.progress.Questy or P.progress["Questy-Realm"]
    assert(q[900] == nil, "Questie's quest gone")
    QS:Store(data, "Stranger-Realm")
    assert(not P.progress.Stranger and not P.progress["Stranger-Realm"], "only from the group")
    -- What we send the party: our log, read as WoW Forever has it (C_QuestLog, no GetQuestLogTitle).
    local realTitle = GetQuestLogTitle
    GetQuestLogTitle = nil
    local encoded = P.Encode()
    GetQuestLogTitle = realTitle
    assert(
        type(encoded) == "table" and encoded[1] and encoded[1]:match("^%d+:"),
        "our log encoded without GetQuestLogTitle: " .. tostring(encoded[1])
    )
    -- Asking: "?" to the party (and a request to Questie players); a "?" heard sends our log.
    local sentParty = {}
    local realChat, realGroup, realRaid, realMembers = C_ChatInfo, IsInGroup, IsInRaid, GetNumGroupMembers
    GetNumGroupMembers = function() return 2 end
    C_ChatInfo = {
        SendAddonMessage = function(prefix, text, channel) table.insert(sentParty, { prefix, text, channel }) end,
    }
    IsInGroup, IsInRaid = function() return true end, function() return false end
    P:Ask()
    local asked = false
    for _, m in ipairs(sentParty) do
        if m[1] == "PWSYNC1" and m[2] == "?" and m[3] == "PARTY" then asked = true end
    end
    assert(asked, "the party asked for its progress")
    assert(#sentParty >= 2 and sentParty[2][1] == "questie", "Questie players asked too")
    sentParty = {}
    P:Ask()
    assert(#sentParty == 0, "not asked again at once")
    C_ChatInfo, IsInGroup, IsInRaid, GetNumGroupMembers = realChat, realGroup, realRaid, realMembers
    UnitInParty = realParty
    -- An "R" leaves the old progress shown until its first chunk comes.
    P.progress = {}
    local realAmb = Ambiguate
    Ambiguate = function(n) return (n:gsub("%-.*", "")) end
    P:Store("Amy", 900, { "3" })
    fire("CHAT_MSG_ADDON", "PWSYNC1", "R", "PARTY", "Amy-Realm")
    assert(#P:Members(900, 1, 8) == 1, "progress kept while a refresh is under way")
    fire("CHAT_MSG_ADDON", "PWSYNC1", "900:5", "PARTY", "Amy-Realm")
    assert(P:Members(900, 1, 8)[1].have == 5, "the chunk replaces it")
    -- Tokens only go up: the first R's timer does not wipe a second R's progress.
    P.progress = {}
    runTimers()
    local refreshes = 0
    local realRefresh = FG.Guide.Refresh
    FG.Guide.Refresh = function() refreshes = refreshes + 1 end
    fire("CHAT_MSG_ADDON", "PWSYNC1", "R", "PARTY", "Amy-Realm")
    local first = P.pending.Amy
    local timer1 = timers[#timers] -- the R's own timer is the last one it queued
    fire("CHAT_MSG_ADDON", "PWSYNC1", "900:5", "PARTY", "Amy-Realm")
    assert(P.pending.Amy == nil and P.progress.Amy[900], "the chunk clears the pending token")
    fire("CHAT_MSG_ADDON", "PWSYNC1", "R", "PARTY", "Amy-Realm")
    assert(P.pending.Amy and P.pending.Amy ~= first, "a new token for the second R")
    local timer2 = timers[#timers]
    assert(timer1 ~= timer2, "one timer per R")
    timer1() -- the first R's timer: its token is no longer current
    assert(P.progress.Amy and P.progress.Amy[900], "the first timer leaves the second R's progress")
    assert(P.pending.Amy, "the second R is still pending")
    refreshes = 0
    timer2() -- the second R's own timer
    assert(P.pending.Amy == nil and P.progress.Amy[900] == nil, "the last timer clears the progress")
    assert(refreshes >= 1, "the timer redraws the guide")
    FG.Guide.Refresh = realRefresh
    -- Asked once per missing quest, until the roster changes; only once a request went out.
    local sentAsk = {}
    local c2, g2, r2, t2 = C_ChatInfo, IsInGroup, IsInRaid, GetTime
    -- The fake clock starts well past the real stub, hence past the askedAt an earlier test left
    -- in Party (the first ask here must go out). The clock restored afterwards carries on from
    -- the fake one, so it never jumps behind the last askedAt and a later ask can pass the throttle.
    local now = t2() + 100
    GetTime = function() return now end
    local function asks()
        local n = 0
        for _, t in ipairs(sentAsk) do
            if t == "?" then n = n + 1 end
        end
        return n
    end
    C_ChatInfo = { SendAddonMessage = function(_, text) table.insert(sentAsk, text) end }
    IsInGroup, IsInRaid = function() return false end, function() return false end
    P.askedFor = {}
    P:AskFor(778)
    assert(not P.askedFor[778] and asks() == 0, "nothing sent outside a group: not marked as asked")
    IsInGroup = function() return true end
    P:AskFor(777)
    P:AskFor(777)
    assert(asks() == 1 and P.askedFor[777], "exactly one ask for a missing quest")
    P:AskFor(778) -- within the throttle: a request is pending, so it counts as asked
    assert(asks() == 1 and P.askedFor[778], "a request inside the throttle marks the quest")
    fire("GROUP_ROSTER_UPDATE")
    assert(P.askedFor[777] == nil, "the flag goes with a roster change")
    -- The guide asks from events: the quest log, a roster change, the guide shown; never a redraw.
    do
        local realObjectives = C_QuestLog.GetQuestObjectives
        C_QuestLog.GetQuestObjectives = function(q)
            if q == 7102 then
                return {
                    {
                        text = "First thing: 0/4",
                        type = "monster",
                        finished = false,
                        numFulfilled = 0,
                        numRequired = 4,
                    },
                    {
                        text = "Second thing: 0/6",
                        type = "monster",
                        finished = false,
                        numFulfilled = 0,
                        numRequired = 6,
                    },
                }
            end
            return realObjectives(q)
        end
        onQuest[7102] = true
        -- No name, two objectives, o = 2: the party line is on objective 2.
        FG.Routes["ask-test"] = {
            race = 7,
            class = 8,
            faction = "Alliance",
            fromLevel = 1,
            toLevel = 60,
            time = 1,
            steps = { { k = "objective", t = "Kill things", q = 7102, o = 2, lvl = 5 } },
        }
        useRoute("ask-test")
        local realInParty = UnitInParty
        UnitInParty = function() return true end
        local saved2 = P.progress
        P.progress = {}
        P.askedFor = {}
        sentAsk = {}
        now = now + 100
        P:Store("Amy", 7102, { "3" }) -- Amy has objective 1 only: objective 2 is missing
        fire("QUEST_LOG_UPDATE")
        fire("QUEST_LOG_UPDATE")
        assert(asks() == 1, "two quest log updates, one ask: " .. asks())
        FG.Guide:Refresh()
        FG.Guide:Refresh()
        assert(asks() == 1, "a redraw sends nothing")
        fire("GROUP_ROSTER_UPDATE")
        now = now + 11
        fire("QUEST_LOG_UPDATE")
        assert(asks() == 2, "asked again after a roster change: " .. asks())
        -- Amy now has objective 2: the no-name step takes its index from `o`, nothing is missing.
        P:Store("Amy", 7102, { "1", "2" })
        fire("GROUP_ROSTER_UPDATE")
        now = now + 11
        fire("QUEST_LOG_UPDATE")
        assert(asks() == 2, "the no-name step finds objective 2 by its index: " .. asks())
        -- Shown again, however (options, key binding): one ask for a missing line.
        P.progress = {}
        FG:Save("guideShown", false)
        now = now + 11
        FG:Save("guideShown", true)
        assert(asks() == 3, "the guide shown asks once: " .. asks())
        P.progress = saved2
        UnitInParty = realInParty
        C_QuestLog.GetQuestObjectives = realObjectives
        onQuest[7102] = nil
    end
    P.askedFor = {}
    local offset = now - t2()
    GetTime = function() return t2() + offset end
    -- A redraw sends nothing.
    local before = #sentAsk
    FG.Guide:Refresh()
    assert(#sentAsk == before, "a redraw sends no addon message")
    C_ChatInfo, IsInGroup, IsInRaid = c2, g2, r2
    Ambiguate = realAmb
    P.progress = saved
    print("party lines ok")
end

-- The party line of the guide viewer (TaskView's v.party): a member's count by objective index,
-- Questie's data through the same index, the step's own index when its name matches nothing, and
-- no line when done, in a raid or with the sync off. Then the "R" timeout.
do
    local P = FG.Party
    local saved = P.progress
    local objectives, isOn, titleOf = C_QuestLog.GetQuestObjectives, C_QuestLog.IsOnQuest, C_QuestLog.GetTitleForQuestID
    local realParty, realGroup, realRaid, realAmb = UnitInParty, IsInGroup, IsInRaid, Ambiguate
    local realChat = C_ChatInfo
    local log = {
        [8801] = { { text = "Wolf Pelt: 2/8", numFulfilled = 2, numRequired = 8, finished = false } },
        [8802] = { { text = "Something Else: 1/4", numFulfilled = 1, numRequired = 4, finished = false } },
        [8803] = { { text = "Wolf Pelt: 8/8", numFulfilled = 8, numRequired = 8, finished = true } },
    }
    C_QuestLog.GetQuestObjectives = function(q) return log[q] or objectives(q) end
    C_QuestLog.IsOnQuest = function(q) return log[q] ~= nil or isOn(q) end
    C_QuestLog.GetTitleForQuestID = function(q) return log[q] and ("Party Quest " .. q) or titleOf(q) end
    UnitInParty = function(name) return name == "Amy" or name == "Questy-Realm" end
    IsInGroup, IsInRaid = function() return true end, function() return false end
    Ambiguate = function(n) return (n:gsub("%-.*", "")) end
    -- Nothing is sent when the guide asks for the party's data.
    C_ChatInfo = { SendAddonMessage = function() end }
    FG.Routes["partyline-test"] = {
        race = 7,
        class = 8,
        faction = "Alliance",
        fromLevel = 1,
        toLevel = 60,
        time = 1,
        steps = {
            { k = "objective", t = "Wolf Pelt x8", q = 8801, o = 1, n = "Wolf Pelt", lvl = 1 },
            { k = "objective", t = "Gather", q = 8802, o = 1, n = "No Such Text", lvl = 1 },
            { k = "objective", t = "Wolf Pelt x8", q = 8803, o = 1, n = "Wolf Pelt", lvl = 1 },
            { k = "grind", t = "Grind", lvl = 60 },
        },
    }
    useRoute("partyline-test")
    P.progress = {}
    local function task(q)
        FG.Guide:Go(q - 8800)
        FG.Guide:Refresh()
        for _, v in ipairs(FG.Guide.view.tasks) do
            if v.step and v.step.q == q then return v end
        end
    end
    -- A member's data: "Name (have/need)".
    P:Store("Amy", 8801, { "5" })
    local v = task(8801)
    assert(v and v.party and #v.party == 1, "the party line of the shown objective")
    assert(v.party[1].name == "Amy" and v.party[1].have == 5 and v.party[1].need == 8, "Amy (5/8)")
    -- Questie's data: an update, then a whole log, stored for a member through the same index.
    P.progress = {}
    local QS = FG.QuestieShare
    QS:Store(
        QS.Serialize({ ver = "1.0.0", msgVer = 5, msgId = 1, quest = { id = 8801, objectives = { { ful = 6 } } } }),
        "Questy-Realm"
    )
    v = task(8801)
    assert(v and v.party and v.party[1].name == "Questy" and v.party[1].have == 6, "a Questie update shown")
    P.progress = {}
    QS:Store(
        QS.Serialize({ ver = "1.0.0", msgVer = 5, msgId = 12, [1] = { 1, 8801, 1, 109, 3, 4, 8 } }),
        "Questy-Realm"
    )
    v = task(8801)
    assert(v and v.party and v.party[1].name == "Questy" and v.party[1].have == 4, "a Questie full list shown")
    -- A name matching no objective text: the step's own index (step.o) finds it.
    P.progress = {}
    P:Store("Amy", 8802, { "3" })
    v = task(8802)
    assert(v and v.party and v.party[1].have == 3 and v.party[1].need == 4, "the step.o fallback: Amy (3/4)")
    -- Done: the row is done, and the card draws no party line for a done row (v.party and not v.done).
    P.progress = {}
    P:Store("Amy", 8803, { "4" })
    v = task(8803)
    assert(v and v.done, "a done objective is a done row")
    assert(not (v.party and not v.done), "a done row draws no party line")
    -- In a raid, or with the sync off: no line.
    P:Store("Amy", 8801, { "5" })
    assert(task(8801).party, "the line is there to begin with")
    IsInRaid = function() return true end
    assert(task(8801).party == nil, "no party line in a raid")
    IsInRaid = function() return false end
    FG:Save("partySync", false)
    assert(task(8801).party == nil, "no party line with partySync off")
    FG:Save("partySync", nil)
    assert(task(8801).party, "and back")
    -- The "R" timeout: no chunk follows, progress is cleared once the timer fires.
    P.progress = {}
    runTimers()
    P:Store("Amy", 8801, { "5" })
    fire("CHAT_MSG_ADDON", "PWSYNC1", "R", "PARTY", "Amy-Realm")
    assert(P.progress.Amy and P.progress.Amy[8801], "kept until the timer fires")
    runTimers()
    assert(P.progress.Amy and P.progress.Amy[8801] == nil, "cleared once the timer fired with no chunk")
    assert(#P:Members(8801, 1, 8) == 0, "no members left on the objective")
    -- A chunk arriving first keeps the timer from clearing it.
    fire("CHAT_MSG_ADDON", "PWSYNC1", "R", "PARTY", "Amy-Realm")
    fire("CHAT_MSG_ADDON", "PWSYNC1", "8801:7", "PARTY", "Amy-Realm")
    runTimers()
    assert(P.progress.Amy[8801] and P.progress.Amy[8801][1] == "7", "a chunk before the timer keeps its data")
    C_QuestLog.GetQuestObjectives, C_QuestLog.IsOnQuest, C_QuestLog.GetTitleForQuestID = objectives, isOn, titleOf
    UnitInParty, IsInGroup, IsInRaid, Ambiguate, C_ChatInfo = realParty, realGroup, realRaid, realAmb, realChat
    P.progress = saved
    useRoute("skip-test")
    print("party line view ok")
end

-- Death skip: done once back at the spirit healer the step stands at.
FG.Routes["deathskip-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1,
    steps = {
        { k = "deathskip", t = "Die and respawn at the spirit healer", m = 1426, x = 80, y = 20, lvl = 5 },
        { k = "deathskip", t = "Die and respawn at the spirit healer", m = 1426, x = 30.1, y = 71.3, lvl = 5 },
        { k = "grind", t = "Grind", lvl = 60 },
    },
}
useRoute("deathskip-test")
fire("QUEST_LOG_UPDATE")
runTimers()
assert(char.guide.step == 1, "far from the spirit healer: not there yet, step " .. char.guide.step)
char.guide.step = 2
fire("QUEST_LOG_UPDATE")
runTimers()
assert(char.guide.step == 3, "back at the spirit healer, step " .. char.guide.step)
print("death skip ok")

-- Group sync: a member's progress shows next to the objective.
Ambiguate = function(name) return (name:gsub("%-.*", "")) end
for _, f in ipairs(frames) do
    if f.events.CHAT_MSG_ADDON and f.OnEvent then
        f:OnEvent("CHAT_MSG_ADDON", "PWSYNC1", "R", "PARTY", "Pata-Realm")
        f:OnEvent("CHAT_MSG_ADDON", "PWSYNC1", "7101:3;33:x", "PARTY", "Pata-Realm")
    end
end
assert(FG.Party:Suffix(7101, 1, 8):find("Pata 3", 1, true), "party progress shown: " .. FG.Party:Suffix(7101, 1, 8))
print("party ok")

do
    -- Group guide: the same guide for two players, Pata (the warrior it is planned for) and us.
    local sentMessages = {}
    C_ChatInfo = { SendAddonMessage = function(prefix, message) table.insert(sentMessages, message) end }
    IsInGroup = function() return true end
    UnitInParty = function(name) return name == "Pata" end
    local function fromPata(message)
        for _, f in ipairs(frames) do
            if f.events.CHAT_MSG_ADDON and f.OnEvent then
                f:OnEvent("CHAT_MSG_ADDON", "PWGRP1", message, "PARTY", "Pata-Realm")
            end
        end
    end
    FG.Routes["group-test"] = {
        race = 7,
        class = 1,
        faction = "Alliance",
        fromLevel = 12,
        toLevel = 14,
        time = 7,
        spells = { 100 },
        classSpells = { [8] = { 200 } },
        players = { { n = "Pata-Realm", race = 1, class = 1 }, { n = "Brouz-Realm", race = 7, class = 8 } },
        syncMax = 1,
        steps = {
            {
                k = "accept",
                t = "Accept A",
                q = 901,
                m = 1426,
                x = 10,
                y = 10,
                lvl = 12,
                px = 0,
                gp = { 12, 0, 12, 100 },
            },
            {
                k = "accept",
                t = "Accept B",
                q = 902,
                m = 1426,
                x = 50,
                y = 50,
                lvl = 12,
                px = 0,
                mb = 1,
                gp = { 12, 0, 12, 100 },
            },
            {
                k = "train",
                t = "Train",
                m = 1426,
                x = 30.1,
                y = 71.3,
                n = "Thran Khorman",
                sp = { 100 },
                lvl = 12,
                gp = { 12, 0, 12, 100 },
            },
            { k = "grind", t = "Pata catches up", lvl = 13, mb = 1, gp = { 13, 50, 13, 100 } },
            { k = "accept", t = "Accept C", q = 903, m = 1426, x = 90, y = 90, lvl = 13, gp = { 13, 50, 13, 100 } },
        },
    }
    completed[902] = true -- we did quest B already: it is Pata's only
    playerLevel = 12
    UnitXP = function() return 100 end
    useRoute("group-test")
    local adapted = FG.Guide:Route()
    assert(adapted.steps[1].lvl == 12 and adapted.steps[1].px == 100, "our own planned XP")
    assert(#adapted.spells == 1 and adapted.spells[1] == 200, "our class's spells")
    assert(#adapted.checkpoints == 0, "no skipping ahead alone")
    assert(
        adapted.steps[3].n == "Marryk Nurribit" and adapted.steps[3].sp == nil,
        "our own class trainer: " .. tostring(adapted.steps[3].n)
    )
    fromPata("S:7:5:1:12:0:8800")
    onQuest[901] = true
    FG.Guide:Advance()
    assert(char.guide.step == 1, "taken, but Pata has not: we wait for Pata, step " .. char.guide.step)
    -- The party is told the first step we have not done ourselves, not the one we wait on: two
    -- players done never wait on each other.
    FG.Group:Tick(FG.Guide:OwnStep())
    assert(sentMessages[#sentMessages]:find("^S:7:5:2:12:100:"), "our own step told: " .. sentMessages[#sentMessages])
    fromPata("S:7:5:2:12:0:8800")
    assert(char.guide.step == 2, "Pata's quest: we wait for Pata, step " .. char.guide.step)
    fromPata("S:7:5:3:12:0:8800")
    assert(char.guide.step == 3, "Pata past it: on, step " .. char.guide.step)
    char.guide.marks[3] = true
    FG.Guide:Advance()
    assert(char.guide.step == 3, "trained, Pata not yet, step " .. char.guide.step)
    fromPata("S:7:5:4:12:0:8800")
    assert(char.guide.step == 4, "Pata catching up: we wait, step " .. char.guide.step)
    fromPata("S:7:5:4:13:60:9400")
    assert(char.guide.step == 5, "Pata caught up, step " .. char.guide.step)
    FG.Guide:SkipCurrent()
    assert(char.guide.step == 5, "marked done by us only: still on it, step " .. char.guide.step)
    local told = false
    for _, m in ipairs(sentMessages) do
        if m:find("^Q:7:5:1:.*903") then told = true end
    end
    assert(told, "our marks told to the party")
    fromPata("Q:7:5:1:903")
    assert(char.guide.step == 6, "marked done by everyone: passed, step " .. char.guide.step)
    -- Pata gone: our marks are enough.
    UnitInParty = function() return false end
    assert(FG.Group:SkipShared(adapted.steps[5], 5), "alone, our marks are enough")
    sentMessages, IsInGroup, UnitInParty, playerLevel = {}, function() return false end, nil, 1
    UnitXP = function() return 0 end
    onQuest[901], completed[902] = nil, nil
    print("group guide ok")
end

do
    -- A group guide made for characters the app had no profile of: we are the player of our
    -- race and class, with our own professions; with two of them, the one chosen in the options.
    local skinning = { key = "skinning", name = "Skinning", line = 393, target = 150, start = 10, curve = {} }
    local function group(players)
        local rewards = #players == 2 and { 0, 100 } or { 0, 100, 103 }
        return {
            race = 1,
            class = 1,
            faction = "Alliance",
            fromLevel = 1,
            toLevel = 3,
            time = 8,
            professions = {},
            players = players,
            syncMax = 1,
            steps = {
                { k = "accept", t = "Accept A", q = 901, m = 1429, x = 50, y = 50, lvl = 1, gp = { 1, 0, 1, 0, 1, 0 } },
                { k = "turnin", t = "Turn in A", q = 901, lvl = 1, rx = 100, rxp = rewards },
            },
        }
    end
    FG.Routes["group-new"] = group({
        { n = "Player 1", race = 1, class = 1, professions = {} },
        { n = "Player 2", race = 7, class = 8, professions = { skinning } },
    })
    assert(FG.Import.Fits(FG.Routes["group-new"]), "a guide of a group we are in fits us")
    useRoute("group-new")
    assert(FG.Group:Active() and not FG.Group:Choices(), "found by race and class")
    assert(FG.Guide:Route().professions[1].key == "skinning", "our own professions")
    assert(FG.Guide:Route().steps[2].rx == 100, "our own quest reward")
    FG.Routes["group-twins"] = group({
        { n = "Player 1", race = 1, class = 1, professions = {} },
        { n = "Player 2", race = 7, class = 8, professions = {} },
        { n = "Player 3", race = 7, class = 8, professions = { skinning } },
    })
    useRoute("group-twins")
    local choices, me = FG.Group:Choices()
    assert(choices and #choices == 2 and me == nil and not FG.Group:Active(), "two of us: to choose")
    FG.Group:Choose(2)
    assert(FG.Group:Active() and select(2, FG.Group:Choices()) == 2, "the one chosen")
    assert(FG.Guide:Route().professions[1].key == "skinning", "the chosen player's professions")
    assert(FG.Guide:Route().steps[2].rx == 103, "the chosen player's buffed quest reward")
    FG.Group:Choose(1)
    assert(FG.Guide:Route().steps[2].rx == 100, "changing player changes its reward")
    FG.Group:Choose(2)
    useRoute("group-new")
    useRoute("group-twins")
    assert(select(2, FG.Group:Choices()) == 2, "the choice is kept for the guide")
    FG.Routes["group-new"], FG.Routes["group-twins"] = nil, nil
    useRoute(nil)
    print("group guide for new characters ok")
end

-- Merchant: grey items are sold.
local sold = 0
C_Container = {
    GetContainerNumSlots = function(bag) return bag == 0 and 2 or 0 end,
    GetContainerItemInfo = function(_, slot)
        return { itemID = 100 + slot, quality = slot == 1 and 0 or 2, stackCount = 1 }
    end,
    UseContainerItem = function() sold = sold + 1 end,
}
C_Item = C_Item or {}
C_Item.GetItemInfo = function() return "Item", nil, nil, nil, nil, nil, nil, nil, nil, nil, 5 end
CanMerchantRepair = function() return false end
for _, f in ipairs(frames) do
    if f.events.MERCHANT_SHOW and f.OnEvent then f:OnEvent("MERCHANT_SHOW") end
end
assert(sold == 1, "one grey item sold, got " .. sold)
print("merchant ok")

-- The toolstrip's trash can: grey items only, the cheapest stack first; a plain click (or a key)
-- destroys nothing, Shift-click destroys that stack, right-click keeps it for good.
do
    local bag = {
        { itemID = 201, quality = 0, stackCount = 2 }, -- 2 x 5 copper
        { itemID = 202, quality = 0, stackCount = 1 }, -- 1 x 5 copper: the cheapest
        { itemID = 203, quality = 1, stackCount = 1 }, -- white: never offered
        { itemID = 204, quality = 0, stackCount = 3 }, -- 3 x 5 copper
    }
    local realContainer, cursor, deleted = C_Container, nil, {}
    C_Container = {
        GetContainerNumSlots = function(b) return b == 0 and #bag or 0 end,
        GetContainerItemInfo = function(b, slot) return b == 0 and bag[slot] or nil end,
        PickupContainerItem = function(_, slot) cursor = bag[slot] end,
    }
    CursorHasItem = function() return cursor ~= nil end
    DeleteCursorItem = function()
        for slot, item in pairs(bag) do
            if item == cursor then bag[slot] = false end
        end
        table.insert(deleted, cursor.itemID)
        cursor = nil
    end
    local function Ids()
        local out = {}
        for _, j in ipairs(FG.Toolstrip.Junk()) do
            table.insert(out, j.id)
        end
        return table.concat(out, ",")
    end
    assert(Ids() == "202,201,204", "grey items only, cheapest first: " .. Ids())
    local trash
    for i = #frames, 1, -1 do
        if frames[i]:GetName() == "PathwrightTrash" then trash = trash or frames[i] end
    end
    assert(trash and trash.OnClick, "the trash can")
    local savedCurrency = C_CurrencyInfo
    C_CurrencyInfo = { GetCoinTextureString = function(value) return "coins(" .. value .. ")" end }
    trash.OnEnter(trash)
    C_CurrencyInfo = savedCurrency
    assert(GameTooltip.lines[2]:find("coins(5)", 1, true), "first stack uses the native coin formatter")
    assert(GameTooltip.lines[#GameTooltip.lines]:find("coins(15)", 1, true), "other stacks show their total value")
    assert(GameTooltip.lines[1] == "Maj+clic pour détruire :", "its tooltip: " .. tostring(GameTooltip.lines[1]))
    trash.OnClick(trash, "LeftButton")
    assert(#deleted == 0, "a plain click destroys nothing")
    IsShiftKeyDown = function() return true end
    trash.OnClick(trash, "LeftButton")
    IsShiftKeyDown = function() return false end
    assert(deleted[1] == 202 and #deleted == 1 and Ids() == "201,204", "Shift-click destroyed the cheapest")
    trash.OnClick(trash, "RightButton")
    assert(Ids() == "204" and #deleted == 1, "right-click kept the next one: " .. Ids())
    assert(FG.Guide:State().keptJunk[201], "kept for this character")
    FG.Guide:State().keptJunk = nil
    C_Container, CursorHasItem, DeleteCursorItem = realContainer, nil, nil
end
print("trash can ok")

-- Quest mobs' nameplates: a sword or a money bag with the count, read from the game's own unit
-- tooltip, then a green check once done; dimmed when tagged by someone else.
do
    local saved = {
        tooltip = C_TooltipInfo,
        plate = C_NamePlate,
        objectives = C_QuestLog.GetQuestObjectives,
        onQuest = C_QuestLog.IsOnQuest,
        name = UnitName,
        tapped = UnitIsTapDenied,
    }
    Enum = Enum or {}
    Enum.TooltipDataLineType = { QuestObjective = 8, QuestTitle = 17, QuestPlayer = 18 }
    local plates, lines, names, tapped = {}, {}, {}, {}
    C_NamePlate = {
        GetNamePlateForUnit = function(unit) return plates[unit] end,
        GetNamePlates = function()
            local list = {}
            for unit, plate in pairs(plates) do
                plate.namePlateUnitToken = unit
                table.insert(list, plate)
            end
            return list
        end,
    }
    local realExists = UnitExists
    UnitExists = function(unit) return plates[unit] ~= nil or realExists(unit) end
    C_TooltipInfo = { GetUnit = function(unit) return { lines = lines[unit] or {} } end }
    UnitName = function(unit) return names[unit] or "Brouz" end
    UnitIsTapDenied = function(unit) return tapped[unit] or false end
    local objectives = {
        [5001] = {
            {
                text = "Kobold Vermin slain: 3/10",
                type = "monster",
                finished = false,
                numFulfilled = 3,
                numRequired = 10,
            },
            { text = "Candle: 1/8", type = "item", finished = false, numFulfilled = 1, numRequired = 8 },
        },
    }
    C_QuestLog.GetQuestObjectives = function(q) return objectives[q] end
    C_QuestLog.IsOnQuest = function(q) return objectives[q] ~= nil end
    local function Title(q) return { type = 17, id = q } end
    local function Objective(text, done, have, need)
        return { type = 8, leftText = text, completed = done, numFulfilled = have, numRequired = need }
    end
    local np = FG.Nameplates
    plates.nameplate1 = CreateFrame("Frame", nil, UIParent)
    names.nameplate1 = "Kobold Vermin"
    lines.nameplate1 = { Title(5001), Objective("Kobold Vermin slain: 3/10", false, 3, 10) }
    np:Update("nameplate1")
    local mark = np.marks.nameplate1
    assert(mark and mark:IsShown() and mark.progress.kind == "kill", "a sword on a mob to kill")
    -- A plate the game will not let us measure still takes the mark; a forbidden one does not.
    plates.nameplate1.IsAnchoringRestricted = function() return true end
    np:Update("nameplate1")
    assert(np.marks.nameplate1, "marked though measuring it is restricted")
    plates.nameplate1.IsForbidden = function() return true end
    np:Update("nameplate1")
    assert(not np.marks.nameplate1, "no mark on a forbidden plate")
    plates.nameplate1.IsForbidden, plates.nameplate1.IsAnchoringRestricted = nil, nil
    np:Update("nameplate1")
    mark = np.marks.nameplate1
    assert(np.Count(mark.progress) == "3/10" and mark.count.text == "3/10", "its count")
    -- In a group the tooltip lists each member's progress under their name: our count is ours, a
    -- party member listed first (at 7/10) changes nothing.
    lines.nameplate1 = {
        Title(5001),
        { type = 18, leftText = "Amy" },
        Objective("Kobold Vermin slain: 7/10", false, 7, 10),
        { type = 18, leftText = "Brouz" },
        Objective("Kobold Vermin slain: 3/10", false, 3, 10),
    }
    np:Update("nameplate1")
    assert(np.Count(np.marks.nameplate1.progress) == "3/10", "our own count, not a party member's")
    lines.nameplate1 =
        { Title(5001), { type = 18, leftText = "Amy" }, Objective("Kobold Vermin slain: 7/10", false, 7, 10) }
    np:Update("nameplate1")
    local only = np.marks.nameplate1
    assert(
        not only or only.progress.owner or np.Count(only.progress) ~= "7/10",
        "only a party member's row: their count never shown as ours"
    )
    lines.nameplate1 = { Title(5001), Objective("Kobold Vermin slain: 3/10", false, 3, 10) }
    np:Update("nameplate1")
    mark = np.marks.nameplate1
    -- A mob that drops a quest item: the money bag.
    plates.nameplate2 = CreateFrame("Frame", nil, UIParent)
    names.nameplate2 = "Kobold Tunneler"
    lines.nameplate2 = { Title(5001), Objective("Candle: 1/8", false, 1, 8) }
    np:Update("nameplate2")
    assert(np.marks.nameplate2.progress.kind == "loot", "a money bag on a mob that drops a quest item")
    local group, members, inParty = IsInGroup, GetNumSubgroupMembers, UnitInParty
    IsInGroup = function() return true end
    GetNumSubgroupMembers = function() return 1 end
    names.party1 = "Pata"
    UnitInParty = function(name) return name == "Pata" end
    local friend = { type = 18, leftText = "Pata" }
    local friendLoot = Objective("Candle: 6/8", false, 6, 8)
    lines.nameplate2 = { Title(5001), friend, friendLoot }
    np:Update("nameplate2")
    local lootMark = np.marks.nameplate2
    assert(lootMark.count.text == "1/8" and lootMark.owner.text == "", "own drop count wins over a party line")
    objectives[5001][2].finished = true
    np:Refresh()
    runTimers()
    assert(lootMark.count.text == "6/8" and lootMark.owner.text == "Pata" and lootMark.progress.kind == "loot")
    lines.nameplate2 = {}
    FG.Party:Store("Pata", 5001, { "x", "5" })
    np:Update("nameplate2")
    assert(lootMark.count.text == "5/8" and lootMark.owner.text == "Pata", "synced count for a known drop")
    FG.Party:Forget("Pata", 5001)
    np:Update("nameplate2")
    assert(lootMark.progress.done and lootMark.owner.text == "", "finished check clears the name")
    lines.nameplate2 = { Title(5002), friend, Objective("Tunneler slain: 4/10", false, 4, 10) }
    np:Update("nameplate2")
    assert(lootMark.count.text == "4/10" and lootMark.owner.text == "Pata", "party-only quest with an identified owner")
    lines.nameplate2 = {
        Title(5002),
        friend,
        Objective("Tunneler slain: 4/10", false, 4, 10),
        Title(5001),
        Objective("Candle: 1/8", false, 1, 8),
    }
    objectives[5001][2].finished = false
    np:Refresh()
    runTimers()
    assert(lootMark.count.text == "1/8" and lootMark.owner.text == "", "later personal objective takes priority")
    lines.nameplate2 = { Title(5001), Objective("Candle: 1/8", false, 1, 8) }
    IsInGroup, GetNumSubgroupMembers, UnitInParty = group, members, inParty
    -- Tagged by another player: dimmed.
    tapped.nameplate2 = true
    np:Update("nameplate2")
    assert(np.marks.nameplate2.tapped and np.marks.nameplate2:GetAlpha() < 1, "dimmed when tagged by someone else")
    FG:Save("questNameplatesTapped", false)
    np:Update("nameplate2")
    assert(np.marks.nameplate2:GetAlpha() == 1, "not dimmed when not asked")
    FG:Save("questNameplatesTapped", nil)
    -- Every objective done: the check, no count.
    objectives[5001][1].finished, objectives[5001][1].numFulfilled = true, 10
    lines.nameplate1 = { Title(5001), Objective("Kobold Vermin slain: 10/10", true, 10, 10) }
    np:Update("nameplate1")
    assert(np.marks.nameplate1.progress.done and np.marks.nameplate1.count.text == "", "the check once done")
    -- The game stops listing a finished objective: the check stays (the mob was seen with it).
    objectives[5001][1].text = "Kobold Vermin slain: 10/10"
    lines.nameplate1 = {}
    fire("QUEST_LOG_UPDATE")
    runTimers()
    assert(np.marks.nameplate1 and np.marks.nameplate1.progress.done, "still the check once the game stops listing it")
    -- Not on our quests: nothing; secret values (instances on WoW Forever): nothing either.
    plates.nameplate3 = CreateFrame("Frame", nil, UIParent)
    names.nameplate3 = "Stray Wolf"
    np:Update("nameplate3")
    assert(not np.marks.nameplate3, "no mark on a mob of no quest")
    local secret = issecretvalue
    issecretvalue = function() return true end
    np:Update("nameplate2")
    assert(not np.marks.nameplate2, "nothing from secret values")
    issecretvalue = secret
    -- Turned off: the marks go.
    FG:Save("questNameplates", false)
    np:Update("nameplate1")
    assert(not np.marks.nameplate1, "no mark when turned off")
    FG:Save("questNameplates", nil)
    C_TooltipInfo, C_NamePlate, UnitName, UnitIsTapDenied = saved.tooltip, saved.plate, saved.name, saved.tapped
    UnitExists = realExists
    C_QuestLog.GetQuestObjectives, C_QuestLog.IsOnQuest = saved.objectives, saved.onQuest
end
print("nameplates ok")

-- Our progress for the group's Questie players, in Questie's own messages (prefix "questie").
do
    local share = FG.QuestieShare
    local p = {
        ver = "1.0.0",
        msgVer = 5,
        msgId = 1,
        quest = { id = 783, objectives = { { id = 6, typ = "m", ful = 3, req = 10 } } },
    }
    local wire = share.Serialize(p)
    assert(not wire:find("\0", 1, true), "no zero byte on the wire")
    local back = share.Deserialize(wire)
    assert(back.msgId == 1 and back.quest.objectives[1].ful == 3 and back.quest.objectives[1].typ == "m", "read back")
    assert(share.Deserialize("not a packet") == nil, "garbage refused")

    local saved = {
        group = IsInGroup,
        raid = IsInRaid,
        members = GetNumGroupMembers,
        chat = C_ChatInfo,
        addons = C_AddOns,
        count = C_QuestLog.GetNumQuestLogEntries,
        info = C_QuestLog.GetInfo,
        objectives = C_QuestLog.GetQuestObjectives,
        party = UnitInParty,
    }
    local sent = {}
    C_ChatInfo = {
        SendAddonMessage = function(prefix, message, channel, target)
            table.insert(
                sent,
                { prefix = prefix, packet = share.Deserialize(message), channel = channel, target = target }
            )
        end,
    }
    local questieHere = false
    C_AddOns = { IsAddOnLoaded = function(name) return name == "Questie" and questieHere end }
    IsInGroup, IsInRaid, GetNumGroupMembers =
        function() return true end, function() return false end, function() return 3 end
    UnitInParty = function(name) return name == "Friend" end
    local log = { 7101 }
    local progress = { [7101] = 2 }
    C_QuestLog.GetNumQuestLogEntries = function() return #log end
    C_QuestLog.GetInfo = function(i) return { questID = log[i], title = "Q", level = 5 } end
    C_QuestLog.GetQuestObjectives = function(q)
        return {
            {
                text = "Kobold Vermin slain",
                type = "monster",
                finished = false,
                numFulfilled = progress[q],
                numRequired = 8,
            },
        }
    end
    share.sent = {}
    share:Update(true)
    assert(#sent == 0, "the log taken as it is, nothing sent")
    progress[7101] = 3
    share:Update()
    local update = sent[1]
    assert(update and update.prefix == "questie" and update.channel == "PARTY", "a progress change sent to the party")
    assert(
        update.packet.msgId == 1 and update.packet.msgVer == 5 and update.packet.ver == "1.0.0",
        "as Questie's message 1"
    )
    local o = update.packet.quest.objectives[1]
    assert(update.packet.quest.id == 7101 and o.ful == 3 and o.req == 8 and o.typ == "m", "its objective")
    assert(o.id == 6, "the mob's ID from the guide: " .. tostring(o.id))
    share:Update()
    assert(#sent == 1, "nothing again while nothing changed")
    -- A friend's Questie asks for our quests: the whole log, whispered back (message 12).
    local request = share.Serialize({ ver = "12.12.0", msgVer = 5, msgId = 11 })
    share:Receive(request, "PARTY", "Friend")
    local reply = sent[2]
    assert(reply and reply.channel == "WHISPER" and reply.target == "Friend" and reply.packet.msgId == 12, "answered")
    local block = reply.packet[1]
    assert(block[1] == 1 and block[2] == 7101 and block[3] == 1 and block[4] == 6, "the quest and its objective")
    assert(block[5] == ("m"):byte() and block[6] == 3 and block[7] == 8, "its type and counts")
    share:Receive(request, "PARTY", "Stranger")
    assert(#sent == 2, "not answered outside the group")
    -- The quest gone from the log: message 2.
    log = {}
    share:Update()
    assert(sent[3] and sent[3].packet.msgId == 2 and sent[3].packet.id == 7101, "a quest gone: message 2")
    -- Questie runs here too: it shares already, we send nothing.
    questieHere = true
    log, progress[7101] = { 7101 }, 4
    share:Update()
    share:Receive(request, "PARTY", "Friend")
    assert(#sent == 3, "nothing sent while Questie runs here")
    questieHere = false
    FG:Save("questieShare", false)
    progress[7101] = 5
    share:Update()
    assert(#sent == 3, "nothing sent when turned off")
    FG:Save("questieShare", nil)
    share.sent = {}
    IsInGroup, IsInRaid, GetNumGroupMembers, C_ChatInfo, C_AddOns =
        saved.group, saved.raid, saved.members, saved.chat, saved.addons
    C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo, C_QuestLog.GetQuestObjectives =
        saved.count, saved.info, saved.objectives
    UnitInParty = saved.party
end
print("questie sharing ok")

-- Merchant, WoW Forever: the item a quest wants is read with C_MerchantFrame (the old
-- GetMerchantItemInfo is gone) and bought.
do
    local realPurchases, realMoney = FG.Guide.Purchases, GetMoney
    local bought = 0
    FG.Guide.Purchases = function() return { [5000] = 2 } end
    GetMoney = function() return 1000 end
    GetMerchantNumItems = function() return 1 end
    GetMerchantItemID = function() return 5000 end
    C_MerchantFrame = {
        GetItemInfo = function() return { price = 10, stackCount = 1, numAvailable = -1 } end,
    }
    BuyMerchantItem = function() bought = bought + 1 end
    fire("MERCHANT_SHOW")
    assert(bought == 2, "two bought for the quest, got " .. bought)
    FG.Guide.Purchases, GetMoney = realPurchases, realMoney
    GetMerchantNumItems, GetMerchantItemID, C_MerchantFrame, BuyMerchantItem = nil, nil, nil, nil
end
print("merchant quest items ok")

-- Merchant supplies on a client without the global GetItemCount (only C_Item.GetItemCount).
do
    local realGet, realMoney, realOpt = GetItemCount, GetMoney, FG.Get
    local bought, carried = 0, 5
    GetItemCount = nil
    local realCI = C_Item.GetItemCount
    C_Item.GetItemCount = function(id) return id == 4540 and carried or 0 end
    GetMoney = function() return 100000 end
    FG.Get = function(self, k)
        if k == "autoSupplies" then return true end
        if k == "suppliesFood" then return 8 end
        if k == "autoSellJunk" or k == "autoRepair" then return false end
        return realOpt(self, k)
    end
    GetMerchantNumItems = function() return 1 end
    GetMerchantItemID = function() return 4540 end
    GetMerchantItemMaxStack = function() return 20 end
    C_MerchantFrame = { GetItemInfo = function() return { price = 10, stackCount = 1, numAvailable = -1 } end }
    BuyMerchantItem = function(_, n) bought = bought + (n or 1) end
    local before = {}
    for msg, n in pairs(PathwrightDB.errors or {}) do
        before[msg] = n
    end
    fire("MERCHANT_SHOW")
    for msg, n in pairs(PathwrightDB.errors or {}) do
        assert(before[msg] == n, "merchant handler raised: " .. msg)
    end
    assert(bought == 3, "supplies bought with only C_Item.GetItemCount, got " .. bought)
    GetItemCount, GetMoney, FG.Get, C_Item.GetItemCount = realGet, realMoney, realOpt, realCI
    GetMerchantNumItems, GetMerchantItemID, GetMerchantItemMaxStack, C_MerchantFrame, BuyMerchantItem =
        nil, nil, nil, nil, nil
end
print("merchant supplies without GetItemCount ok")

-- Skins: a skin registered through the public API styles every frame made so far.
local skinned = {}
PathwrightAPI.RegisterSkin("Test", function(frame, kind) skinned[kind] = (skinned[kind] or 0) + 1 end)
assert(skinned.window == 3, "windows skinned: the card, the minimal strip and the guide browser")
assert((skinned.panel or 0) >= 1, "panels skinned")
assert(#PathwrightAPI.GetFrames() >= 2)
assert(FG.Skin:Suite() == nil, "no UI suite in the tests")
print("skins ok")

-- Compass: straight ahead, to the left, behind (angles counter-clockwise, as the game's facing).
local close = function(a, b) return math.abs(a - b) < 1e-9 end
assert(close(FG.Compass.Angle(10, 0, 0), 0), "north, facing north: ahead")
assert(close(FG.Compass.Angle(0, 10, 0), math.pi / 2), "west, facing north: to the left")
assert(close(FG.Compass.Angle(0, -10, math.pi / 2), math.pi), "east, facing west: behind")
assert(close(FG.Compass.Angle(0, 10, math.pi / 2), 0), "west, facing west: ahead")
assert(close(FG.Compass.Left(FG.Compass.Angle(0, -10, 0)), -90), "east, facing north: 90° to the right")
print("compass angles ok")

-- A step whose mobs live in several places: the arrow moves on from a place where the character
-- waited out of combat (nothing there), and on "Next spot"; around again once all are visited.
do
    local now, fighting = 100, false
    local realTime, realCombat = GetTime, UnitAffectingCombat
    GetTime = function() return now end
    UnitAffectingCombat = function() return fighting end
    FG.Routes["spots"] = {
        race = 7,
        class = 8,
        faction = "Alliance",
        fromLevel = 1,
        toLevel = 2,
        steps = {
            {
                k = "objective",
                t = "Kill Lost Stalker",
                q = 900,
                o = 1,
                m = 1426,
                x = 29.93,
                y = 71.2,
                lvl = 1,
                spots = { { m = 1426, x = 50, y = 50 }, { m = 1426, x = 10, y = 10 } },
            },
        },
    }
    onQuest[900] = true
    local before, beforeStep = char.guide.route, char.guide.step
    useRoute("spots")
    FG.Guide:Refresh()
    assert(waypoint.x == 0.2993, "its own place first")
    now, fighting = 130, true
    FG.Guide:Refresh()
    now, fighting = 145, false
    FG.Guide:Refresh()
    assert(waypoint.x == 0.2993, "fighting there: something to find, stays")
    now = 170
    FG.Guide:Refresh()
    assert(waypoint.x == 0.5 and waypoint.y == 0.5, "waited there out of combat: the closest other place")
    Press("spot")
    assert(waypoint.x == 0.1, "next spot: the next one")
    Press("spot")
    assert(waypoint.x == 0.2993, "all visited: around again from the closest")
    local places, at = FG.Guide:SpotPlaces()
    assert(#places == 3 and at == 1, "the places for the map pins")
    onQuest[900] = nil
    useRoute(before)
    FG.Guide:Go(beforeStep)
    GetTime, UnitAffectingCombat = realTime, realCombat
    print("spots ok")
end

-- An NPC who patrols (Gordo on Tirisfal's road, GitHub #20): its spots are along its path and
-- the arrow points first at the one closest to the character, not at the step's own place.
do
    local realCombat = UnitAffectingCombat
    UnitAffectingCombat = function() return false end
    FG.Routes["patrol"] = {
        race = 7,
        class = 8,
        faction = "Alliance",
        fromLevel = 1,
        toLevel = 2,
        steps = {
            {
                k = "accept",
                t = "Accept Gordo's Task from Gordo (patrols: look along the path)",
                q = 901,
                m = 1426,
                x = 80,
                y = 80,
                lvl = 1,
                pt = true,
                spots = { { m = 1426, x = 50, y = 50 }, { m = 1426, x = 30, y = 70 } },
            },
        },
    }
    local before, beforeStep = char.guide.route, char.guide.step
    useRoute("patrol")
    FG.Guide:Refresh()
    assert(waypoint.x == 0.3 and waypoint.y == 0.7, "the place of its path closest to the character")
    local places, at = FG.Guide:SpotPlaces()
    assert(#places == 3 and at == 3, "its own place and its path's")
    useRoute(before)
    FG.Guide:Go(beforeStep)
    UnitAffectingCombat = realCombat
    print("patrol ok")
end

-- Profile: what the app plans a guide from, saved at login, logout and with "Save the profile now".
local profile = PathwrightDB.profiles["Brouz-Realm"]
assert(profile and profile.level == 1 and profile.race == 7 and profile.class == "MAGE", "profile saved")
assert(profile.rested == 600 and profile.xp_max == 400 and profile.resting, "XP and rested XP")
assert(profile.gear[1] == 6125, "gear worn")
assert(profile.bind.name == "Coldridge Valley" and not profile.bind.position, "hearthstone, place unknown")
bindLocation = "Kharanos"
fire("CHAT_MSG_SYSTEM", "Kharanos is now your home.")
assert(profile.bind.name == "Kharanos" and profile.bind.position.map == 1426, "hearthstone bound here")
C_TaxiMap.GetAllTaxiNodes = function()
    return { { nodeID = 6, state = 0 }, { nodeID = 7, state = 1 }, { nodeID = 8, state = 2 } }
end
fire("TAXIMAP_OPENED")
assert(profile.flights[6] and profile.flights[7] and not profile.flights[8], "flight paths known")
C_QuestLog.GetQuestObjectives = function()
    return { { text = "Tough Wolf Meat: 3/8", numFulfilled = 3, numRequired = 8, finished = false } }
end
C_QuestLog.GetAllCompletedQuestIDs = function() return { 179, 233 } end
Press("profile")
assert(reloaded, "the interface reloads to write the profile")
assert(#profile.completed == 2, "quests done")
assert(profile.log[1].id == 233 and profile.log[1].objectives[1].done == 3, "log with its objectives")
print("profile ok")

-- Window size: Ctrl + mouse wheel over a window, or the setting; saved, nothing: the default.
FG:Save("scale", 1.3)
assert(FG:Get("scale") == 1.3 and PathwrightDB.settings.scale == 1.3, "scale saved")
local wheel = FG.Card:Frame()
fire("MODIFIER_STATE_CHANGED", "LCTRL", 1)
wheel.OnMouseWheel(wheel, 1)
assert(FG:Get("scale") == 1.35, "zoomed in: " .. FG:Get("scale"))
FG:Save("scale", nil)
assert(FG:Get("scale") == 1 and PathwrightDB.settings.scale == nil, "back to the default size")
print("scale ok")

-- A part of the profile the game fails to give keeps its previous value, the error is kept.
local inventory = GetInventoryItemID
GetInventoryItemID = function() error("gone") end
FG.Profile:Snapshot()
assert(profile.gear[1] == 6125 and profile.errors.gear, "gear kept")
assert(#profile.log == 1, "the other parts are saved")
GetInventoryItemID = inventory
FG.Profile:Snapshot()
assert(not profile.errors, "no error left")
print("profile parts ok")

-- Reputations: every faction of the panel, those under a collapsed header too (opened for the
-- reading, closed again), headers without points of their own left out.
local factionRows = {
    { name = "Alliance", header = true, id = 469 },
    { name = "Darnassus", id = 69, value = 4200, parent = "Alliance" },
    { name = "Other", header = true, collapsed = true, id = 169 },
    { name = "Booty Bay", id = 21, value = 2900, parent = "Other" },
}
local function visibleFactions()
    local out, hidden = {}, {}
    for _, f in ipairs(factionRows) do
        if f.header and f.collapsed then hidden[f.name] = true end
        if not (f.parent and hidden[f.parent]) then table.insert(out, f) end
    end
    return out
end
local function setCollapsed(i, collapsed) visibleFactions()[i].collapsed = collapsed end
C_Reputation = {
    GetNumFactions = function() return #visibleFactions() end,
    GetFactionDataByIndex = function(i)
        local f = visibleFactions()[i]
        return f
            and {
                factionID = f.id,
                name = f.name,
                currentStanding = f.value or 0,
                isHeader = f.header or false,
                isCollapsed = f.collapsed or false,
                isHeaderWithRep = false,
            }
    end,
    ExpandFactionHeader = function(i) setCollapsed(i, false) end,
    CollapseFactionHeader = function(i) setCollapsed(i, true) end,
}
FG.Profile:Snapshot()
local function points(list)
    local out = {}
    for _, r in ipairs(list or {}) do
        out[r.id] = r.value
    end
    return out
end
local seen = points(profile.reputation)
assert(seen[69] == 4200 and seen[21] == 2900 and not seen[469] and not seen[169], "reputations, collapsed ones too")
assert(factionRows[3].collapsed, "the collapsed header closed again")
-- The minute's snapshot: the panel is not opened again (the game would tell every addon) until
-- the game says a reputation changed.
do
    local expanded, expand = 0, C_Reputation.ExpandFactionHeader
    C_Reputation.ExpandFactionHeader = function(i)
        expanded = expanded + 1
        expand(i)
    end
    factionRows[2].value = 4250
    FG.Profile:Snapshot(false)
    assert(expanded == 0 and points(profile.reputation)[69] == 4200, "not read again without a change")
    fire("CHAT_MSG_COMBAT_FACTION_CHANGE", "Reputation with Darnassus increased by 50.")
    FG.Profile:Snapshot(false)
    assert(expanded == 1 and points(profile.reputation)[69] == 4250, "read again after a gain")
    C_Reputation.ExpandFactionHeader = expand
end
C_Reputation = nil
-- Classic Era and TBC: the older globals.
GetNumFactions = function() return #visibleFactions() end
GetFactionInfo = function(i)
    local f = visibleFactions()[i]
    return f.name, "", 4, 0, 0, f.value or 0, false, false, f.header, f.collapsed, false, false, f.parent ~= nil, f.id
end
ExpandFactionHeader = function(i) setCollapsed(i, false) end
CollapseFactionHeader = function(i) setCollapsed(i, true) end
factionRows[2].value = 4300
FG.Profile:Snapshot()
seen = points(profile.reputation)
assert(seen[69] == 4300 and seen[21] == 2900 and factionRows[3].collapsed, "reputations on Classic")
GetNumFactions, GetFactionInfo, ExpandFactionHeader, CollapseFactionHeader = nil, nil, nil, nil
print("reputations ok")

-- Quests to pick up: the next accepts not done that can be taken now (quests needed done,
-- level reached), the hand-picked one pointed at until done.
playerLevel = 21
FG.Routes["pickup-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1,
    steps = {
        { k = "accept", t = "Accept First", q = 6001, m = 1426, x = 30, y = 71, lvl = 21 },
        { k = "accept", t = "Accept Follow-up", q = 6002, pre = { 6001 }, m = 1426, x = 30, y = 72, lvl = 21 },
        { k = "accept", t = "Accept Later", q = 6003, min = 30, m = 1426, x = 31, y = 71, lvl = 21 },
        { k = "accept", t = "Accept Either", q = 6004, pa = { 6005, 6001 }, m = 1426, x = 31, y = 72, lvl = 21 },
        { k = "accept", t = "Accept Close", q = 6006, m = 1426, x = 32, y = 71, lvl = 21 },
        { k = "grind", t = "Grind", lvl = 60 },
    },
}
FG:Set("pickupLines", 10)
useRoute("pickup-test")
local function pickups() return table.concat(FG.Guide:Pickups(FG:Get("pickupLines")), ",") end
assert(pickups() == "1,5", "only quests that can be taken now: " .. pickups())
completed[6001] = true
assert(pickups() == "2,4,5", "their prerequisites done: " .. pickups())
FG:Set("pickupLines", 1)
assert(pickups() == "2", "as many as configured: " .. pickups())
FG.Guide:PointToStep(5)
assert(waypoint and waypoint.x == 0.32, "hand-picked step pointed at")
FG.Guide:Advance()
assert(waypoint.x == 0.32, "still pointed at after a refresh")
waypoint = nil -- moved or cleared by something else
FG.Guide:PointToStep(5)
assert(waypoint and waypoint.x == 0.32, "the step pointed at again sets the game's waypoint again")
onQuest[6006] = true
FG.Guide:Advance()
assert(waypoint.x ~= 0.32, "back to the route once taken")
print("pickups ok")

-- An accept whose prerequisite was skipped (here, or planned by an earlier built-in guide and
-- never done) is passed, and its follow-ups with it; a prerequisite no guide plans is not judged.
do
    local routes = FG.Routes
    FG.Builtin.Register({
        name = "prelost-first",
        next = "prelost-test",
        variants = { { race = 7, class = 8, faction = "Alliance" } },
        steps = { { k = "accept", t = "Accept Earlier", q = 6101, lvl = 21 } },
    })
    FG.Builtin.Register({
        name = "prelost-test",
        variants = { { race = 7, class = 8, faction = "Alliance" } },
        steps = {
            { k = "accept", t = "Accept Start", q = 6110, lvl = 21 },
            { k = "accept", t = "Accept Chain", q = 6111, pa = { 6110 }, lvl = 21 },
            { k = "accept", t = "Accept Chain 2", q = 6112, pre = { 6111 }, lvl = 21 },
            { k = "accept", t = "Accept After Earlier", q = 6113, pa = { 6101 }, lvl = 21 },
            { k = "accept", t = "Accept Unplanned", q = 6114, pa = { 6199 }, lvl = 21 },
            { k = "grind", t = "Grind", lvl = 60 },
        },
    })
    FG.Import:Apply()
    for name, r in pairs(routes) do
        FG.Routes[name] = FG.Routes[name] or r
    end
    useRoute("prelost-test")
    assert(char.guide.step == 1, "nothing skipped yet, step " .. char.guide.step)
    FG.Guide:ToggleSkip(1)
    fire("QUEST_LOG_UPDATE")
    runTimers()
    assert(char.guide.step == 5, "the chain and the earlier guide's follow-up passed, step " .. char.guide.step)
    completed[6101] = true
    FG.Guide:Resync()
    assert(char.guide.step == 4, "its prerequisite done: taken again, step " .. char.guide.step)
    completed[6101] = nil
    FG.Guide:ToggleSkip(1)
    FG.Guide:Resync()
    assert(char.guide.step == 1, "unskipped: the chain is back, step " .. char.guide.step)
    FG.Guide:CloseTab("prelost-test")
    table.remove(FG.Builtin.defs)
    table.remove(FG.Builtin.defs)
    FG.Routes = routes
    print("prerequisites lost ok")
end

-- Grind steps count the XP of the quests complete in the log the route turns in before the
-- level they aim at, not of those it turns in later.
playerLevel = 3
FG.Routes["pending-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1,
    steps = {
        { k = "grind", t = "Be level 3 and 300 xp", lvl = 3, xp = 300 },
        { k = "turnin", t = "Turn in Soon", q = 7001, rx = 400, lvl = 3 },
        { k = "turnin", t = "Turn in Reaching 4", q = 7003, rx = 900, lvl = 4 },
        { k = "turnin", t = "Turn in Later", q = 7002, rx = 500, lvl = 5 },
        { k = "grind", t = "Grind", lvl = 60 },
    },
}
local complete = {}
onQuest[7001], onQuest[7002], onQuest[7003] = true, true, true
local log = { 7002, 7003, 7001 }
C_QuestLog.GetNumQuestLogEntries = function() return #log end
C_QuestLog.GetInfo = function(i) return { questID = log[i], title = "Q" .. log[i], level = 3 } end
local isComplete = C_QuestLog.IsComplete
C_QuestLog.IsComplete = function(q) return complete[q] or false end
useRoute("pending-test")
assert(char.guide.step == 1, "not enough XP yet, step " .. char.guide.step)
complete[7002] = true
FG.Guide:Advance()
assert(char.guide.step == 1, "a quest turned in after the level does not count")
complete[7003] = true
FG.Guide:Advance()
assert(char.guide.step == 2, "the turn-in reaching the level counts, step " .. char.guide.step)
FG.Guide:Go(1)
complete[7003] = nil
complete[7001] = true
FG.Guide:Resync()
assert(char.guide.step == 2, "a quest turned in before the level counts, step " .. char.guide.step)
C_QuestLog.IsComplete = isComplete
print("pending xp ok")

-- Just accepted, the game has no objectives yet and may say the quest complete: the kill step
-- is not skipped for it (Polestar #74, Kolkar Leaders went straight to the hand-in).
FG.Routes["loading-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1,
    steps = {
        { k = "accept", t = "Accept Kolkar Leaders", q = 9301, id = 1, m = 1426, x = 29.93, y = 71.2, lvl = 3 },
        { k = "objective", t = "Kill Barak", q = 9301, o = 1, n = "Barak Kodobane", lvl = 3 },
        { k = "turnin", t = "Turn in Kolkar Leaders", q = 9301, rx = 500, id = 2, m = 1426, x = 50, y = 50, lvl = 3 },
        { k = "grind", t = "Grind", lvl = 60 },
    },
}
local loading, loadingDone = nil, false
local objectivesBefore, numEntries, getInfo =
    C_QuestLog.GetQuestObjectives, C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo
C_QuestLog.GetQuestObjectives = function(q)
    if q == 9301 then return loading end
    return objectivesBefore(q)
end
C_QuestLog.IsComplete = function(q) return q == 9301 and (loading == nil or loadingDone) end
C_QuestLog.GetNumQuestLogEntries = function() return 1 end
C_QuestLog.GetInfo = function() return { questID = 9301, title = "Kolkar Leaders", level = 3 } end
useRoute("loading-test")
assert(char.guide.step == 1, "accept first, step " .. char.guide.step)
onQuest[9301] = true
-- QUEST_ACCEPTED would add a collector row the checks further down do not expect.
fire("QUEST_LOG_UPDATE")
runTimers()
assert(char.guide.step == 2, "no objectives yet: not done, step " .. char.guide.step)
loading = { { text = "", finished = false } }
fire("QUEST_LOG_UPDATE")
runTimers()
assert(char.guide.step == 2, "blank objectives: not done, step " .. char.guide.step)
loading = { { text = "Barak Kodobane slain: 0/1", finished = false } }
fire("QUEST_LOG_UPDATE")
runTimers()
assert(char.guide.step == 2, "objective not finished, step " .. char.guide.step)
loading, loadingDone = { { text = "Barak Kodobane slain: 1/1", finished = true } }, true
fire("QUEST_LOG_UPDATE")
runTimers()
assert(char.guide.step == 3, "objective finished, step " .. char.guide.step)
-- The same while grinding: its XP is not counted before the objectives are there.
FG.Routes["loading-test"].steps[1] = { k = "grind", t = "Be level 3 and 300 xp", lvl = 3, xp = 300 }
loading, loadingDone = nil, false
useRoute("loading-test")
FG.Guide:Go(1)
FG.Guide:Resync()
assert(char.guide.step == 1, "loading quest XP not counted, step " .. char.guide.step)
loading, loadingDone = { { text = "Barak Kodobane slain: 1/1", finished = true } }, true
FG.Guide:Resync()
assert(char.guide.step > 1, "complete quest XP counted, step " .. char.guide.step)
C_QuestLog.GetQuestObjectives, C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo =
    objectivesBefore, numEntries, getInfo
C_QuestLog.IsComplete = isComplete
onQuest[9301] = nil
print("objectives loading ok")

-- XP plan: where the guide expects the character before the step shown and after its tasks.
FG.Routes["xp-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1,
    steps = {
        { k = "accept", t = "Accept A", q = 8001, lvl = 3, px = 150 },
        { k = "accept", t = "Accept B", q = 8002, lvl = 3, px = 250 },
        { k = "grind", t = "Grind", lvl = 60, px = 0 },
    },
}
playerLevel = 3
useRoute("xp-test")
onQuest[8001] = true
FG.Guide:Advance()
assert(char.guide.step == 2, "step " .. char.guide.step)
local level, xp = FG.XpPlan:Planned()
assert(level == 3 and xp == 150, "planned before step 2: " .. tostring(level) .. " " .. tostring(xp))
local unitXP, unitXPMax = UnitXP, UnitXPMax
UnitXP, UnitXPMax = function() return 100 end, function() return 1000 end
local share, from, to = FG.XpPlan:Shares()
assert(
    share == 0.1 and from == 0.15 and to == 0.25,
    "shares: " .. share .. " " .. tostring(from) .. " " .. tostring(to)
)
-- On the bar: a hollow box from the XP expected before the current tasks to after them, the
-- character's XP showing inside; the mark alone without an end.
do
    local function texture()
        local t = { points = {} }
        function t:SetShown(shown) self.shown = shown end
        function t:ClearAllPoints() self.points = {} end
        function t:SetPoint(_, _, _, x) table.insert(self.points, x) end
        function t:SetWidth(w) self.width = w end
        function t:SetHeight() end
        return t
    end
    local bar = { track = {}, fill = texture(), mark = texture() }
    bar.box = { top = texture(), bottom = texture(), left = texture(), right = texture() }
    FG.XpPlan:Draw(bar, 200)
    assert(bar.fill.width == 20, "the character's XP: " .. tostring(bar.fill.width))
    assert(bar.box.top.shown and bar.box.left.shown and not bar.mark.shown, "a box, no mark")
    assert(bar.box.top.points[1] == 29 and bar.box.top.points[2] == 51, "the box from 15% to 25% of the bar")
    local realAfter = FG.XpPlan.PlannedAfter
    FG.XpPlan.PlannedAfter = function() return nil end
    FG.XpPlan:Draw(bar, 200)
    assert(bar.mark.shown and not bar.box.top.shown, "no end planned: the mark alone")
    FG.XpPlan.PlannedAfter = realAfter
end
playerLevel = 1
share, from = FG.XpPlan:Shares()
assert(from == 1, "two levels behind: the planned mark at the bar's end")
UnitXP, UnitXPMax, playerLevel = unitXP, unitXPMax, 3
print("xp plan ok")

-- A sell step is done once a merchant's window opens while it is shown.
FG.Routes["sell-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1,
    steps = {
        {
            k = "sell",
            t = "Sell your loot to Tharynn Bouden",
            e = "npc",
            id = 66,
            m = 1429,
            x = 41.9,
            y = 67.1,
            lvl = 3,
        },
        { k = "accept", t = "Accept C", q = 8003, lvl = 3 },
    },
}
useRoute("sell-test")
assert(char.guide.step == 1, "on the sell step")
fire("MERCHANT_SHOW")
FG.Guide:Advance()
assert(char.guide.step == 2, "sold: step " .. char.guide.step)
print("sell step ok")

-- A step of a kind made by a newer app is shown by its text and done right away.
FG.Routes["other-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1,
    steps = {
        { k = "accept", t = "Accept C", q = 8003, lvl = 3 },
        { k = "someday", t = "Do something new", lvl = 3 },
        { k = "accept", t = "Accept D", q = 8004, lvl = 3 },
    },
}
useRoute("other-test")
FG.Guide:Advance()
assert(char.guide.step == 1, "on the accept step")
onQuest[8003] = true
FG.Guide:Advance()
assert(char.guide.step == 3, "the unknown step passed: step " .. char.guide.step)
onQuest[8003] = nil
print("unknown step kind ok")

-- Wide groups the app once marked (`gj`) are not followed: only the same spot or NPC groups.
FG.Routes["groups-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1,
    steps = {
        { k = "accept", t = "Accept D", q = 8004, lvl = 3, m = 1429, x = 10, y = 10 },
        { k = "accept", t = "Accept E", q = 8005, lvl = 3, m = 1429, x = 40, y = 40, gj = true },
        { k = "accept", t = "Accept F", q = 8006, lvl = 3, m = 1429, x = 10, y = 11, gj = true },
    },
}
useRoute("groups-test")
local group = FG.Guide:CurrentSteps()
assert(#group == 1 and group[1] == 1, "the far step is not grouped: " .. table.concat(group, ","))
print("marked groups ignored ok")

-- Objectives done in the same place are one page (GitHub #41, Deathknell): the bats' wings, the
-- heals, the skeletons and the paws, their mobs next to each other; the checkpoint between them
-- does not cut the page and comes last; the town's visits before them are a page of their own
-- (the wings are not on the spot), a far camp is the next page.
do
    local level = playerLevel
    playerLevel = 2
    local spotsOf = function(...)
        local out = {}
        for i = 1, select("#", ...), 2 do
            table.insert(out, { m = 1420, x = select(i, ...), y = select(i + 1, ...) })
        end
        return out
    end
    FG.Routes["area-test"] = {
        race = 5,
        class = 2,
        faction = "Horde",
        fromLevel = 1,
        toLevel = 10,
        time = 1,
        steps = {
            {
                k = "accept",
                t = "Accept The Damned from Novice Elreth",
                q = 8101,
                m = 1420,
                x = 30.86,
                y = 66.05,
                e = "npc",
                id = 1661,
                lvl = 2,
            },
            {
                k = "objective",
                t = "Duskbat Wing x6",
                q = 8101,
                o = 1,
                m = 1420,
                x = 33.31,
                y = 67.39,
                spots = spotsOf(35.75, 71.09, 29.74, 70.72, 29.12, 63.8),
                e = "item",
                id = 3264,
                n = "Duskbat Wing",
                c = 6,
                lvl = 2,
            },
            {
                k = "sell",
                t = "Sell your loot to Harold Raims",
                m = 1420,
                x = 32.4,
                y = 66.43,
                e = "npc",
                id = 2117,
                lvl = 2,
            },
            {
                k = "grind",
                t = "Before level 3: be level 2 and 87% to go on (grind here if behind)",
                m = 1420,
                x = 32.4,
                y = 66.43,
                kp = true,
                lvl = 2,
                xp = 348,
            },
            {
                k = "objective",
                t = "Heal Injured Deathguard with Holy Light",
                q = 8102,
                o = 1,
                m = 1420,
                x = 31.99,
                y = 63.95,
                lvl = 3,
            },
            {
                k = "objective",
                t = "Kill Rattlecage Skeleton x12",
                q = 8103,
                o = 1,
                m = 1420,
                x = 33,
                y = 61.63,
                lvl = 3,
            },
            {
                k = "objective",
                t = "Scavenger Paw x6",
                q = 8104,
                o = 1,
                m = 1420,
                x = 34.87,
                y = 61.16,
                spots = spotsOf(36.79, 56.29, 33.61, 67.71, 29.95, 63.15),
                lvl = 3,
            },
            { k = "turnin", t = "Turn in Rattling the Rattlecages", q = 8103, m = 1420, x = 30.89, y = 66.2, lvl = 3 },
            {
                k = "objective",
                t = "Kill Young Night Web Spider x10",
                q = 8105,
                o = 1,
                m = 1420,
                x = 24.82,
                y = 59.63,
                lvl = 4,
            },
        },
    }
    useRoute("area-test")
    local town = FG.Guide:CurrentSteps()
    assert(#town == 1, "the town's visit alone: " .. table.concat(town, ","))
    onQuest[8101] = true
    FG.Guide:Advance()
    local group = FG.Guide:CurrentSteps()
    assert(
        #group == 7 and group[1] == 2 and group[7] == 8,
        "the objectives of the place are one page: " .. table.concat(group, ",")
    )
    local order = {}
    for _, v in ipairs(FG.Guide.view.tasks) do
        table.insert(order, v.index)
    end
    assert(order[#order] == 4, "the checkpoint last: " .. table.concat(order, ","))
    completed[8101] = true
    onQuest[8101] = nil
    FG.Guide:Advance()
    assert(char.guide.step == 3, "on to the vendor: step " .. char.guide.step)
    fire("MERCHANT_SHOW")
    FG.Guide:Advance()
    assert(char.guide.step == 5, "the heals before the checkpoint: step " .. char.guide.step)
    for q = 8102, 8104 do
        completed[q] = true
    end
    FG.Guide:Advance()
    assert(char.guide.step == 4, "the page stays on the checkpoint not reached: step " .. char.guide.step)
    playerLevel = 3
    FG.Guide:Advance()
    assert(char.guide.step == 9, "the far camp is the next page: step " .. char.guide.step)
    for q = 8101, 8104 do
        completed[q] = nil
    end
    playerLevel = level
end
print("objectives of a place grouped ok")

-- A guide loaded on a character that went on without it (or a new version of the guide, which
-- drops the marks of the visits): the merchant, trainer and inn visits before the last quest handed
-- in are done, the ones after it are not (GitHub #44).
FG.Routes["visits-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1,
    steps = {
        { k = "sell", t = "Sell", e = "npc", id = 66, m = 1429, x = 41.9, y = 67.1, lvl = 3 },
        { k = "accept", t = "Accept A", q = 8201, lvl = 3 },
        { k = "train", t = "Train", e = "npc", id = 67, m = 1429, x = 40, y = 60, lvl = 3 },
        { k = "turnin", t = "Turn in A", q = 8201, lvl = 3 },
        { k = "bind", t = "Bind", e = "npc", id = 68, m = 1429, x = 40, y = 61, lvl = 4 },
        { k = "accept", t = "Accept B", q = 8202, lvl = 4 },
    },
}
completed[8201] = true
useRoute("visits-test")
assert(char.guide.step == 5, "visits before the last turn-in are done, step " .. char.guide.step)
assert(char.guide.marks[1] and char.guide.marks[3] and not char.guide.marks[5], "only the visits behind")
completed[8201] = nil

-- A bind step done already: the hearthstone is bound to the inn of the innkeeper.
FG.Routes["bind-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1,
    steps = {
        { k = "bind", t = "Bind", e = "npc", id = 5688, m = 1420, x = 61.72, y = 52.05, lvl = 1 },
        { k = "accept", t = "Accept B", q = 8221, lvl = 1 },
    },
}
bindLocation = "Kharanos"
useRoute("bind-test")
assert(char.guide.step == 1, "bound to another inn: the bind step stays, step " .. char.guide.step)
bindLocation = "Gallows' End Tavern"
useRoute("bind-test")
assert(char.guide.step == 2, "bound to the inn already: the bind step is passed, step " .. char.guide.step)
-- Another language: the profile saw the bind next to the innkeeper.
bindLocation = "Taverne de la Fin des gibets"
profile.bind = { name = bindLocation, areas = {}, position = { map = 1420, x = 61.7, y = 52 } }
useRoute("bind-test")
assert(char.guide.step == 2, "bound here in another language, step " .. char.guide.step)
profile.bind = { name = bindLocation, areas = {} }
useRoute("bind-test")
assert(char.guide.step == 1, "an unknown inn in another language stays, step " .. char.guide.step)
-- Another language, nothing seen at the binding, the inn from the guide's own `ia`.
FG.Routes["bind-ia-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1,
    steps = {
        {
            k = "bind",
            t = "Bind",
            e = "npc",
            id = 6928,
            m = 1429,
            x = 40,
            y = 61,
            inn = "Lions Rest",
            ia = { 4411 },
            lvl = 1,
        },
        { k = "accept", t = "Accept B", q = 8222, lvl = 1 },
    },
}
bindLocation = "Auberge du Lion"
profile.bind = { name = bindLocation, areas = { 4411 } }
useRoute("bind-ia-test")
assert(char.guide.step == 2, "bound to the step's inn by area id alone, step " .. char.guide.step)
profile.bind = { name = bindLocation, areas = { 9999 } }
useRoute("bind-ia-test")
assert(char.guide.step == 1, "another inn's area id keeps the step, step " .. char.guide.step)
-- English name written by the guide for an innkeeper the addon has no table entry for.
bindLocation = "Lions Rest"
profile.bind = nil
useRoute("bind-ia-test")
assert(char.guide.step == 2, "the step's own inn name passes it, step " .. char.guide.step)
-- A binding seen near the innkeeper, on another map than the step's: compared in world yards.
bindLocation = "Auberge du Lion"
profile.bind = { name = bindLocation, areas = {}, position = { map = 1429, x = 40.2, y = 61.1 } }
useRoute("bind-ia-test")
assert(char.guide.step == 2, "a binding next to the innkeeper passes, step " .. char.guide.step)
profile.bind = { name = bindLocation, areas = {}, position = { map = 1429, x = 55, y = 61 } }
useRoute("bind-ia-test")
assert(char.guide.step == 1, "a binding at another inn keeps the step, step " .. char.guide.step)
profile.bind = nil
bindLocation = "Kharanos"
-- The bind step as the guide builder wrote it (the built-in Undead Starter guide, Innkeeper Renee):
-- the player's report was a hearthstone bound in Brill's tavern, the step left to play.
do
    local renee, base
    local before = #FG.Builtin.defs
    assert(loadfile("addon/Pathwright_Guide/Builtin/UndeadStarter113.lua"))()
    for i = before + 1, #FG.Builtin.defs do
        local def = FG.Builtin.defs[i]
        do
            for v = 1, #def.variants do
                local r = FG.Builtin.Expand(def, v)
                for _, st in ipairs(r.steps) do
                    if st.k == "bind" and st.id == 5688 and not renee then
                        renee, base = st, r
                    end
                end
            end
        end
    end
    for _ = before + 1, #FG.Builtin.defs do
        table.remove(FG.Builtin.defs)
    end
    assert(renee, "the Undead Starter guide has the bind step of Innkeeper Renee")
    assert(renee.inn == "Gallows' End Tavern", "the step names the inn GetBindLocation says: " .. tostring(renee.inn))
    local step = {}
    for k, v in pairs(renee) do
        step[k] = v
    end
    FG.Routes["bind-builtin-test"] = {
        race = base.race,
        class = base.class,
        faction = base.faction,
        fromLevel = 1,
        toLevel = 60,
        time = 1,
        steps = { step, { k = "accept", t = "Accept B", q = 8223, lvl = 1 } },
    }
    profile.bind = nil
    bindLocation = "Gallows' End Tavern"
    useRoute("bind-builtin-test")
    assert(char.guide.step == 2, "bound in Brill's tavern: the built-in bind step is passed, step " .. char.guide.step)
    bindLocation = "Kharanos"
    useRoute("bind-builtin-test")
    assert(char.guide.step == 1, "bound to another inn: the built-in bind step stays, step " .. char.guide.step)
    -- Another language: the tavern's area ids, found by the profile for its name there.
    bindLocation = "Taverne de la Fin des gibets"
    profile.bind = { name = bindLocation, areas = { renee.ia[1] } }
    useRoute("bind-builtin-test")
    assert(char.guide.step == 2, "the tavern by its area id in another language, step " .. char.guide.step)
    profile.bind = { name = bindLocation, areas = { 166 } }
    useRoute("bind-builtin-test")
    assert(char.guide.step == 1, "another place's area id keeps the step, step " .. char.guide.step)
    profile.bind = nil
    bindLocation = "Kharanos"
end
print("bind step ok")

-- A quest handed in far ahead of the guide (found on the way, done out of order) does not pass
-- the visits before it: only those followed by a quest step done, up to the first one not done.
FG.Routes["visits-ahead-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1,
    steps = {
        { k = "accept", t = "Accept A", q = 8211, lvl = 3 },
        { k = "sell", t = "Sell", e = "npc", id = 66, m = 1429, x = 41.9, y = 67.1, lvl = 3 },
        { k = "accept", t = "Accept B", q = 8212, lvl = 3 },
        { k = "train", t = "Train", e = "npc", id = 67, m = 1429, x = 40, y = 60, lvl = 3 },
        { k = "accept", t = "Accept C", q = 8213, lvl = 3 },
        { k = "turnin", t = "Turn in C", q = 8213, lvl = 3 },
    },
}
onQuest[8211] = true
completed[8213] = true
useRoute("visits-ahead-test")
assert(char.guide.step == 2, "the merchant after the quest taken waits, step " .. char.guide.step)
assert(not char.guide.marks[2] and not char.guide.marks[4], "visits before a quest not taken stay")
onQuest[8211], completed[8213] = nil, nil
print("visits passed ok")

-- A dungeon run followed by its quests is done on entering the dungeon, then each quest step as
-- the quest progresses; without them (guides made before), once back out of the dungeon.
local inside = false
IsInInstance = function() return inside end
local function dungeonRoute(name, withQuests)
    local steps = { { k = "dungeon", t = "Dungeon: The Deadmines with a group", lvl = 21 } }
    if withQuests then steps[2] = { k = "objective", t = "Red Silk Bandanas", q = 8001, di = true, lvl = 21 } end
    steps[#steps + 1] = { k = "grind", t = "Grind", lvl = 60 }
    FG.Routes[name] =
        { race = 7, class = 8, faction = "Alliance", fromLevel = 1, toLevel = 60, time = 1, steps = steps }
end
onQuest[8001] = true
dungeonRoute("dungeon-test", true)
useRoute("dungeon-test")
assert(char.guide.step == 1, "the run first, step " .. char.guide.step)
inside = true
fire("ZONE_CHANGED_NEW_AREA")
assert(char.guide.step == 2, "run done on entering, step " .. char.guide.step)
inside = false
dungeonRoute("dungeon-old", false)
useRoute("dungeon-old")
inside = true
fire("ZONE_CHANGED_NEW_AREA")
assert(char.guide.step == 1, "an old run is not done inside")
inside = false
fire("ZONE_CHANGED_NEW_AREA")
assert(char.guide.step == 2, "an old run is done back out, step " .. char.guide.step)
onQuest[8001] = nil
print("dungeon ok")

-- A dungeon's steps are one group, however far apart: shown together until each is done (out of
-- the instance again too), or left aside at once with their quests, and taken back by undoing.
FG.Routes["dungeon-group"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1,
    steps = {
        {
            k = "dungeon",
            t = "Dungeon: The Deadmines with a group",
            n = "The Deadmines",
            m = 1436,
            x = 42,
            y = 72,
            lvl = 18,
        },
        { k = "accept", t = "Accept The Defias Brotherhood", q = 8101, di = true, m = 1436, x = 10, y = 10, lvl = 18 },
        { k = "objective", t = "Edwin VanCleef", q = 8102, di = true, m = 1436, x = 90, y = 90, lvl = 18 },
        { k = "turnin", t = "Turn in The Defias Brotherhood", q = 8101, di = true, m = 1436, x = 50, y = 20, lvl = 19 },
        { k = "grind", t = "Grind", lvl = 60 },
    },
}
useRoute("dungeon-group")
do
    local view = FG.Guide.view
    assert(#view.tasks == 4, "the dungeon's steps shown together, " .. #view.tasks)
    assert(view.dungeon and view.dungeon.name == "The Deadmines" and view.dungeon.steps == 4, "the dungeon bar")
end
inside = true
fire("ZONE_CHANGED_NEW_AREA")
onQuest[8101] = true
FG.Guide:Advance()
assert(char.guide.step == 3, "on the dungeon's next step, step " .. char.guide.step)
assert(FG.Guide.view.dungeon.steps == 2, "two steps left, " .. FG.Guide.view.dungeon.steps)
inside = false
fire("ZONE_CHANGED_NEW_AREA")
assert(char.guide.step == 3, "still in the dungeon out of the instance, step " .. char.guide.step)
FG.Guide:SkipDungeon()
assert(char.guide.skippedQuests[8101] and char.guide.skippedQuests[8102], "its quests left aside")
assert(char.guide.step == 5, "past the dungeon, step " .. char.guide.step)
assert(FG.Guide.view.dungeon == nil, "no dungeon bar after it")
FG.Guide:UndoLastMark()
assert(not char.guide.skippedQuests[8101] and not char.guide.skippedQuests[8102], "taken back")
assert(char.guide.step == 3, "back in the dungeon, step " .. char.guide.step)
onQuest[8101] = nil
print("dungeon group ok")

-- Only the guide's quests: those it still takes, not those it abandons, marked done by hand or
-- out of it. Never an escort, nor one shared by the group.
FG:Save("autoAccept", nil)
FG.Routes["accept-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1,
    steps = {
        { k = "abandon", t = "Abandon Unwanted (not in this guide)", q = 9001, lvl = 21 },
        { k = "accept", t = "Accept Wanted", q = 9002, lvl = 21 },
        { k = "accept", t = "Accept Skipped", q = 9003, lvl = 21 },
        { k = "accept", t = "Accept Escort", q = 9004, es = true, lvl = 21 },
        { k = "grind", t = "Grind", lvl = 60 },
    },
}
useRoute("accept-test")
local questID = GetQuestID
local function taken(q)
    calls.AcceptQuest = nil
    GetQuestID = function() return q end
    fire("QUEST_DETAIL", 0)
    return calls.AcceptQuest ~= nil
end
assert(not taken(9001), "a quest the guide abandons is not taken")
assert(taken(9002), "a quest of the guide is taken")
FG.Guide:ToggleSkip(3) -- right click on its step
assert(not taken(9003), "a quest marked done by hand is not taken")
assert(not taken(9999), "a quest out of the guide is not taken")
assert(not taken(9004), "an escort of the guide is not taken")
FG:Save("routeQuestsOnly", false)
assert(not taken(9004), "an escort is not taken with every quest either")
assert(taken(9999), "a quest out of the guide is taken with every quest")
FG:Save("routeQuestsOnly", nil)
-- Classic and TBC have no quests taken on sight (no QuestGetAutoAccept).
local autoAccept = QuestGetAutoAccept
QuestGetAutoAccept = nil
assert(taken(9002), "a quest of the guide is taken on Classic")
assert(not taken(9999), "a quest out of the guide is not taken on Classic")
QuestGetAutoAccept = autoAccept
-- Quest greeting: a quest of the guide is opened; one without ID (older clients) is opened too,
-- its dialog decides.
local greeting = {}
GetNumAvailableQuests = function() return #greeting end
GetNumActiveQuests = function() return 0 end
GetAvailableQuestInfo = function(i) return false, 0, false, false, greeting[i] end
SelectAvailableQuest = record("SelectAvailableQuest")
local function opened(ids)
    greeting, calls.SelectAvailableQuest = ids, nil
    fire("QUEST_GREETING")
    return calls.SelectAvailableQuest and calls.SelectAvailableQuest[1]
end
assert(opened({ 9999, 9002 }) == 2, "the guide's quest opened")
assert(opened({ 9999 }) == nil, "a quest out of the guide is not opened")
assert(opened({ 0 }) == 1, "a quest without ID is opened")
calls.ConfirmAcceptQuest = nil
FG:Save("routeQuestsOnly", false)
fire("QUEST_ACCEPT_CONFIRM", "Friend", "Shared Escort")
assert(not calls.ConfirmAcceptQuest, "a shared escort is not confirmed")
FG:Save("routeQuestsOnly", nil)
GetQuestID = questID
print("guide quests only ok")

-- Mobs on the way: the XP of the kills of the character (or its pet) counted for the current
-- step. The XP is read on the XP bar, a gain counts when a kill is seen within a second of it.
do
    local savedGetTime, savedXP, savedXPMax, savedLevel = GetTime, UnitXP, UnitXPMax, playerLevel
    local savedGUID = UnitGUID
    UnitGUID = function(u) return u == "pet" and "Pet-0-1-2-3-416-0000000001" or savedGUID(u) end
    -- The game's kill XP messages (the client's own strings).
    COMBATLOG_XPGAIN_FIRSTPERSON = "%s dies, you gain %d experience."
    COMBATLOG_XPGAIN_EXHAUSTION1 = "%s dies, you gain %d experience. (%s exp %s bonus)"
    local clock, barXP, barMax = 5000, 0, 400
    GetTime = function() return clock end
    UnitXP = function() return barXP end
    UnitXPMax = function() return barMax end
    playerLevel = 1
    local function gain(n)
        barXP = barXP + n
        if barXP >= barMax then
            barXP, playerLevel = barXP - barMax, playerLevel + 1
        end
        fire("PLAYER_XP_UPDATE", "player")
    end
    --- The time for the gains to be settled (a kill's signals may come after its XP).
    local function settle()
        clock = clock + 1.5
        runTimers()
        clock = clock + 1.5
        runTimers()
    end
    local function kill(source, dest) fire("PARTY_KILL", source, dest) end
    FG.Routes["farm-test"] = {
        race = 7,
        class = 8,
        faction = "Alliance",
        fromLevel = 1,
        toLevel = 60,
        time = 1,
        steps = { { k = "grind", t = "Grind", lvl = 60, fk = 3, fx = 1300 } },
    }
    useRoute("farm-test")
    fire("PLAYER_ENTERING_WORLD")
    char.guide.farm = nil
    -- A kill then its XP; the XP then the kill and the game's message of the same kill (one gain).
    kill("Player-1-2", "Creature-0-1-2-3-299-0000")
    gain(50)
    settle()
    assert(char.guide.farm and char.guide.farm.step == 1 and char.guide.farm.xp == 50, "a kill's XP counted")
    gain(40)
    kill("Pet-0-1-2-3-416-0000000001", "Creature-0-1-2-3-299-0001")
    fire("CHAT_MSG_COMBAT_XP_GAIN", "Mangy Wolf dies, you gain 40 experience.")
    settle()
    assert(char.guide.farm.xp == 90, "the pet's kill counted once: " .. char.guide.farm.xp)
    -- XP without a kill (a quest turned in, an area discovered): not counted. Nor someone else's
    -- kill, nor a player killed.
    clock = clock + 5
    gain(200)
    kill("Player-9-9", "Creature-0-1-2-3-299-0002")
    settle()
    kill("Player-1-2", "Player-3-4")
    gain(10)
    settle()
    assert(char.guide.farm.xp == 90, "quest XP not counted: " .. char.guide.farm.xp)
    -- A quest turned in right after a kill, its XP read in the same gain: the kill's part only.
    kill("Player-1-2", "Creature-0-1-2-3-299-0003")
    fire("QUEST_TURNED_IN", 1234, 35, 0)
    gain(35 + 35) -- one reading for both
    settle()
    assert(char.guide.farm.xp == 125, "turn-in XP taken off a kill's gain: " .. char.guide.farm.xp)
    -- A kill told by the game's message only (shared in a group, the GUID secret), across a level up.
    assert(barXP == 370, barXP)
    fire("CHAT_MSG_COMBAT_XP_GAIN", "Mangy Wolf dies, you gain 150 experience. (75 exp Rested bonus)")
    gain(150)
    settle()
    assert(playerLevel == 2 and char.guide.farm.xp == 275, "kill XP across a level up: " .. char.guide.farm.xp)
    local rows = FG.Guide:Box().rows
    local farmLine, stepLine = rows[1].count:GetText(), rows[2].name:GetText()
    assert(farmLine == "275/1,300 XP", "a line of its own with the XP: " .. farmLine)
    assert(not stepLine:find("275", 1, true) and stepLine:find("Grind", 1, true), "the step's line apart: " .. stepLine)
    -- Guides made before the XP was exported: the kills are counted.
    FG.Routes["farm-test"].steps[1].fx = nil
    FG.Guide:Refresh()
    farmLine = FG.Guide:Box().rows[1].count:GetText()
    assert(farmLine == "3/3", "guides without the XP count the kills: " .. farmLine)
    -- The mobs of an objective of the guide (killed for it, or dropping its item) are not mobs on
    -- the way while that objective is not finished; then they are.
    FG.Routes["farm-quest-test"] = {
        race = 7,
        class = 8,
        faction = "Alliance",
        fromLevel = 1,
        toLevel = 60,
        time = 1,
        steps = {
            {
                k = "objective",
                t = "Kill Night Web Spider x8",
                n = "Night Web Spider",
                q = 9401,
                o = 1,
                e = "npc",
                id = 1505,
                mi = { 1505 },
                fk = 3,
                fx = 300,
                m = 1431,
                x = 24.8,
                y = 59.7,
                lvl = 1,
            },
            {
                k = "objective",
                t = "Spider Silk x4",
                n = "Spider Silk",
                q = 9402,
                o = 1,
                e = "item",
                id = 9999,
                mi = { 1504 },
                m = 1431,
                x = 24.9,
                y = 59.8,
                lvl = 1,
            },
            { k = "grind", t = "Grind", lvl = 60 },
        },
    }
    playerLevel = 2
    onQuest[9401], onQuest[9402] = true, true
    useRoute("farm-quest-test")
    FG.Guide:Resync()
    char.guide.farm = nil
    kill("Player-1-2", "Creature-0-1-2-3-1505-0000") -- the objective's mob
    gain(30)
    settle()
    kill("Player-1-2", "Creature-0-1-2-3-1504-0001") -- drops the item of an objective
    gain(30)
    settle()
    assert(char.guide.farm == nil, "the mobs of objectives in progress not counted on the way")
    kill("Player-1-2", "Creature-0-1-2-3-299-0002")
    gain(25)
    settle()
    assert(char.guide.farm and char.guide.farm.xp == 25, "another mob counted")
    -- The spiders' objective finished (killing more is farming), then the silk's quest out of the log.
    local objectives = C_QuestLog.GetQuestObjectives
    C_QuestLog.GetQuestObjectives = function(q)
        if q == 9401 then return { { text = "Night Web Spider slain: 8/8", finished = true } } end
        return objectives(q)
    end
    kill("Player-1-2", "Creature-0-1-2-3-1505-0003")
    gain(30)
    settle()
    assert(char.guide.farm.xp == 55, "objective done: its mobs count: " .. char.guide.farm.xp)
    kill("Player-1-2", "Creature-0-1-2-3-1504-0004")
    gain(30)
    settle()
    assert(char.guide.farm.xp == 55, "the silk's objective still in progress")
    onQuest[9402] = nil
    kill("Player-1-2", "Creature-0-1-2-3-1504-0005")
    gain(30)
    settle()
    assert(char.guide.farm.xp == 85, "quest out of the log: its mobs count: " .. char.guide.farm.xp)
    C_QuestLog.GetQuestObjectives = objectives
    onQuest[9401], onQuest[9402] = nil, nil
    GetTime, UnitXP, UnitXPMax, playerLevel, UnitGUID = savedGetTime, savedXP, savedXPMax, savedLevel, savedGUID
end
print("farm on the way ok")

-- Start over: asks when steps or quests were marked by hand, then undoes them.
useRoute("skip-test")
char.guide.skippedQuests[5004] = true
char.guide.marks[1] = "skip"
calls.StaticPopup_Show = nil
Press("restart")
assert(calls.StaticPopup_Show and calls.StaticPopup_Show[1] == "PATHWRIGHT_RESET", "asked first")
FG.Guide:Reset()
for q in pairs(char.guide.skippedQuests) do
    error("quest still marked by hand: " .. q)
end
for _, mark in pairs(char.guide.marks) do
    assert(mark ~= "skip", "no step marked by hand left")
end
calls.StaticPopup_Show = nil
FG.Guide:AskReset()
assert(not calls.StaticPopup_Show, "nothing to undo: no question")
-- A step without a quest marked by hand, undone with the window's button.
FG.Guide:ToggleSkip(5)
assert(char.guide.marks[5] == "skip", "step marked")
Press("undo")
assert(char.guide.marks[5] == nil, "step mark undone")
-- The time per level, in the chat.
local printed = {}
local realPrint = print
print = function(text) printed[#printed + 1] = text end
Press("time")
print = realPrint
assert(#printed > 0, "time per level printed")
print("start over ok")

-- The next steps' tab, kept.
FG:Save("nextTab", "pickup")
assert(FG:Get("nextTab") == "pickup" and PathwrightDB.settings.nextTab == "pickup", "tab kept")
FG.Guide:Refresh()
FG:Save("nextTab", nil)
assert(FG:Get("nextTab") == "next", "default back")
print("next steps tab ok")

-- The compass: the target, the other current task, the quest to pick up close by (not the far
-- one) and the next turn-in.
FG.Routes["compass-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1,
    steps = {
        { k = "objective", t = "Kill A", n = "A", q = 8001, o = 1, id = 1, m = 1426, x = 29.93, y = 71.2, lvl = 1 },
        { k = "objective", t = "Kill B", n = "B", q = 8002, o = 1, id = 1, m = 1426, x = 29.95, y = 71.25, lvl = 1 },
        { k = "turnin", t = "Turn in A", q = 8001, id = 3, m = 1426, x = 40, y = 40, lvl = 1 },
        { k = "accept", t = "Accept Close", q = 8003, id = 4, m = 1426, x = 30, y = 71.3, lvl = 1 },
        { k = "accept", t = "Accept Far", q = 8004, id = 5, m = 1426, x = 50, y = 50, lvl = 1 },
        { k = "grind", t = "Grind", lvl = 60 },
    },
}
onQuest[8001], onQuest[8002] = true, true
useRoute("compass-test")
local byIndex = {}
for _, p in ipairs(FG.Compass:Points()) do
    byIndex[p.index] = p
end
assert(byIndex[1] and byIndex[1].main, "the target first")
assert(byIndex[2] and not byIndex[2].main, "the other task")
assert(byIndex[3] and byIndex[3].kind == "turnin", "the next turn-in")
assert(byIndex[4] and byIndex[4].kind == "accept", "the close quest to pick up")
assert(not byIndex[5], "not the far quest to pick up")
-- Clicking the other task's point: the guide points at it.
FG.Guide:PointToStep(2)
assert(FG.Compass:Points()[1].index == 2 and FG.Compass:Points()[1].main, "the point clicked is the target")
onQuest[8001], onQuest[8002] = nil, nil
print("compass points ok")

-- With Poulpix UI Immersive the guide's windows fade with its HUD, and are full under the mouse.
assert(FG.Poulpix.Alpha(0.2, false) == 0.2 and FG.Poulpix.Alpha(0.2, true) == 1, "faded, full under the mouse")
print("poulpix ok")

-- The compass's places (tests/fixtures/Services.lua): for a gnome mage, the mage trainer, not
-- another class's nor the Horde's, the flight masters; not the trainer of a profession neither
-- learned nor planned, the innkeepers (off by default), the stable masters (hunters), the far
-- ones. A kind turned on shows; a profession the guide plans shows its trainers.
do
    local function Names()
        local names = {}
        for _, p in ipairs(FG.Nearby:Around(0, 299.3, 712)) do
            names[p.name] = p
        end
        return names
    end
    local names = Names()
    assert(names["Marryk Nurribit"] and names["Marryk Nurribit"].service == "class", "the mage trainer")
    assert(not names["Thran Khorman"] and not names["Horde Mage"], "not another class's nor the Horde's")
    assert(names["Flight Master"], "flight masters by default")
    assert(not names["Innkeeper"] and not names["Stable Master"], "no innkeepers by default, stables for hunters")
    assert(not names["Far Mage Trainer"] and not names["Smith"], "not the far ones nor other professions")
    FG:Set("compassInn", true)
    assert(Names()["Innkeeper"], "innkeepers turned on")
    FG:Set("compassInn", nil)
    local route = FG.Guide:Route()
    route.professions = { { line = 197 } }
    FG.Nearby:Forget()
    assert(Names()["Tailor"] and not Names()["Smith"], "the trainers of a profession the guide plans")
    route.professions = nil
    FG.Nearby:Forget()

    -- A click on a place: the compass and the game's waypoint point at it, until reached.
    FG.Guide:PointToPlace(names["Flight Master"])
    local first = FG.Compass:Points()[1]
    assert(first.main and first.place and first.name == "Flight Master", "the place is the target")
    assert(waypoint and close(waypoint.x, 0.32), "the waypoint on the place")
    local realPosition = C_Map.GetPlayerMapPosition
    C_Map.GetPlayerMapPosition = function()
        return { GetXY = function() return 0.32, 0.712 end }
    end
    FG.Guide:Refresh()
    first = FG.Compass:Points()[1]
    assert(first.main and not first.place and first.index, "reached: back to the guide's step")
    C_Map.GetPlayerMapPosition = realPosition

    -- The compass turned off.
    FG:Set("compassShown", false)
    assert(#FG.Compass:Points() == 0, "no compass")
    FG:Set("compassShown", nil)
    assert(#FG.Compass:Points() > 0, "the compass back")
    -- Hidden and shown in game (the window's compass button), kept.
    Press("compass")
    assert(
        FG:Get("compassShown") == false and PathwrightDB.settings.compassShown == false,
        "compass button: hidden, kept"
    )
    assert(#FG.Compass:Points() == 0, "compass button: no compass")
    Press("compass")
    assert(FG:Get("compassShown") == true and #FG.Compass:Points() > 0, "compass button again: back")
    FG:Save("compassShown", nil)
end
print("compass places ok")

-- The planned walk (`wp`: its start and turns, world yards): the compass points along it, a bit
-- ahead of its closest point; going back to it when beside it; not when far from it, nor on its
-- last leg (straight to the place), nor with the setting off.
FG.Routes["walk-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1,
    steps = {
        {
            k = "accept",
            t = "Accept Far",
            q = 8101,
            id = 6,
            m = 1426,
            x = 40,
            y = 71.2,
            lvl = 1,
            wp = { 299, 712, 299, 800, 400, 800 },
        },
        {
            k = "objective",
            t = "Kill wolves",
            n = "Wolf",
            q = 8102,
            o = 1,
            id = 7,
            m = 1426,
            x = 35,
            y = 71.2,
            lvl = 1,
        },
        { k = "grind", t = "Grind", lvl = 60 },
    },
}
useRoute("walk-test")
do
    local n, w, back = FG.Pathing:Aim(0, 299.3, 712)
    assert(n and math.abs(n - 299) < 1 and math.abs(w - 742) < 1 and not back, "along the first leg")
    n, w, back = FG.Pathing:Aim(0, 240, 712)
    assert(n and math.abs(w - 742) < 1 and back, "beside the walk: back to it")
    assert(FG.Pathing:Aim(0, 0, 712) == nil, "far from the walk")
    FG:Set("pathMode", "off")
    assert(FG.Pathing:Aim(0, 299.3, 712) == nil, "the walk turned off")
    FG:Set("pathMode", nil)
    assert(FG.Pathing:Aim(0, 400, 790) == nil, "on the last leg: straight to the place")
    assert(FG.Pathing:Aim(0, 299.3, 712) == nil, "a leg passed is not pointed at again")
end
print("walk ok")

-- Shortest Path Forever: the target sent once, with what stands there; while it guides, no
-- walk on the compass ("auto") and the game's waypoint is its; a journey the player replaces is
-- not sent again until picked on the compass; an objective stays held on its quest's area;
-- the compass follows its way; unlinked, the journey is cancelled.
do
    local sent, current, ended, subscribers = {}, nil, nil, {}
    ShortestPathForever = {
        API = {
            NavigateRoute = function(owner, stops)
                table.insert(sent, { owner = owner, stop = stops[1] })
                current = 1
                return true
            end,
            CurrentStop = function() return current end,
            Ended = function() return ended end,
            Cancel = function()
                current, ended = nil, "cancelled"
                return true
            end,
            Subscribe = function(fn)
                table.insert(subscribers, fn)
                return function() end
            end,
        },
    }
    FG.Pathing:Forget()
    useRoute("walk-test")
    assert(#sent == 1 and sent[1].owner == "Pathwright", "the target sent")
    local stop = sent[1].stop
    assert(stop.map == 1426 and close(stop.x, 0.4) and close(stop.y, 0.712) and stop.kind == "pickup", "where and what")
    waypoint = nil
    FG.Guide:Refresh()
    assert(#sent == 1, "sent once")
    assert(waypoint == nil, "the game's waypoint left to it")
    assert(FG.Pathing:Aim(0, 299.3, 712) == nil, "no walk on the compass while it guides")

    current, ended = nil, "replaced"
    for _, fn in ipairs(subscribers) do
        fn({ ended = true })
    end
    FG.Guide:Refresh()
    assert(#sent == 1, "the player's journey kept")
    assert(waypoint ~= nil, "the game's waypoint back")
    FG.Pathing:Forget()
    FG.Guide:PointToStep(1)
    assert(#sent == 2, "picked on the compass: sent again")

    onQuest[8102] = true
    FG.Guide:PointToStep(2)
    stop = sent[#sent].stop
    assert(stop.kind == "objective" and stop.hold and stop.questID == 8102 and stop.radius, "an objective held")
    onQuest[8102] = nil

    -- Its way on the compass and the arrow: the next point it leads to on the guide's journey
    -- (not on the player's own, nor with the walk forced or off), its leg's words, and the way
    -- to another continent.
    local guidance = { owner = "Pathwright", leg = 1, index = 1, point = { map = 1426, x = 0.31, y = 0.75 } }
    local api = ShortestPathForever.API
    api.Guidance = function()
        if not guidance then return nil, "paused" end
        return guidance
    end
    api.Journey = function() return { owner = "Pathwright", legs = { { mode = "walk", text = "Walk to the dock" } } } end
    FG.Guide:PointToStep(1)
    local n, w, back = FG.Pathing:Aim(0, 299.3, 712)
    assert(close(n, 310) and close(w, 750) and not back, "its next point")
    assert(FG.Pathing:Way().text == "Walk to the dock", "its leg's words")
    assert(FG.Pathing:Aim(1, 299.3, 712) == nil, "its point on another continent")
    assert(FG.Pathing:Remaining(0, 299.3, 712) == nil, "its way is drawn by it")
    FG:Set("pathMode", "on")
    n, w = FG.Pathing:Aim(0, 299.3, 712)
    assert(n and math.abs(w - 742) < 1, "the guide's walk forced")
    FG:Set("pathMode", "off")
    assert(FG.Pathing:Aim(0, 299.3, 712) == nil, "no way with it off")
    FG:Set("pathMode", nil)
    guidance.point.x = 0.32
    assert(close(FG.Pathing:Aim(0, 299.3, 712), 310), "read again only when it changes")
    for _, fn in ipairs(subscribers) do
        fn({ guidance = true })
    end
    assert(close(FG.Pathing:Aim(0, 299.3, 712), 320), "a turn passed: its next point")
    guidance.owner = nil
    for _, fn in ipairs(subscribers) do
        fn({ changed = true })
    end
    assert(FG.Pathing:Aim(0, 299.3, 712) == nil, "the player's own journey is not followed")
    guidance = nil
    FG.Pathing:Forget()
    FG.Guide:PointToStep(1)
    assert(FG.Pathing:Aim(0, 299.3, 712) == nil, "no point to give: none")

    FG:Set("spfLink", false)
    assert(current == nil and ended == "cancelled", "unlinked: cancelled")
    FG:Set("spfLink", nil)
    ShortestPathForever = nil
    FG.Pathing:Forget()
end
print("shortest path ok")

-- The walk drawn on the maps: what is left of it from where the character is (its closest point
-- on it, then its turns, then the place), dots along it, and where they go on the minimap (north
-- up, or turned with the character).
do
    onQuest[8102] = true
    FG.Guide:PointToStep(2)
    onQuest[8102] = nil
    FG.Guide:PointToStep(1)
    local left = FG.Pathing:Remaining(0, 299.3, 712)
    assert(#left == 4 and math.abs(left[1][1] - 299) < 1 and math.abs(left[1][2] - 712) < 1, "from its closest point")
    assert(left[2][2] == 800 and left[3][1] == 400 and math.abs(left[4][1] - 400) < 1, "its turns, then the place")
    left = FG.Pathing:Remaining(0, 240, 712)
    assert(left[1][1] == 240 and #left == 5, "beside it: from the character")
    FG:Set("pathMode", "off")
    assert(FG.Pathing:Remaining(0, 299.3, 712) == nil, "not drawn when off")
    FG:Set("pathMode", nil)

    local dots = FG.PathLines.Sample({ { 0, 0 }, { 0, 10 } }, 5, 100)
    assert(#dots == 3 and dots[3][2] == 10, "a dot every step")
    assert(#FG.PathLines.Sample({ { 0, 0 }, { 0, 100 } }, 5, 4) == 4, "at most so many")
    local x, y = FG.PathLines.OnMinimap(10, 0, 2, nil)
    assert(close(x, 0) and close(y, 20), "north: up")
    x, y = FG.PathLines.OnMinimap(0, 10, 2, nil)
    assert(close(x, -20) and close(y, 0), "west: left")
    x, y = FG.PathLines.OnMinimap(0, 10, 2, math.pi / 2)
    assert(math.abs(x) < 1e-9 and close(y, 20), "facing west on a turning minimap: west is up")
    -- The dots' sizes are settings; larger ones are further apart, smaller ones no closer.
    local size, apart = FG.PathLines.DotSize("pathDotSize")
    assert(size == 5 and apart == 1, "the minimap's dots as before: " .. tostring(size))
    size, apart = FG.PathLines.DotSize("pathMapDotSize")
    assert(size == 6 and apart == 1, "the world map's dots as before: " .. tostring(size))
    FG:Set("pathDotSize", 10)
    FG:Set("pathMapDotSize", 3)
    size, apart = FG.PathLines.DotSize("pathDotSize")
    assert(size == 10 and apart == 2, "twice as large, twice as far apart")
    size, apart = FG.PathLines.DotSize("pathMapDotSize")
    assert(size == 3 and apart == 1, "smaller dots keep their spacing")
    FG:Set("pathDotSize", nil)
    FG:Set("pathMapDotSize", nil)
end
print("walk on the maps ok")

-- The NPC pointed at is marked above its head when its nameplate shows: a place picked on the
-- compass (Marryk Nurribit, NPC 944), on the nameplate showing him, gone with it, back when it
-- shows again.
do
    local realGUID, realExists = UnitGUID, UnitExists
    local plates = { nameplate2 = "Creature-0-1-2-3-299-0000", nameplate3 = "Creature-0-1-2-3-944-0000" }
    UnitGUID = function(u) return plates[u] or realGUID(u) end
    UnitExists = function(u) return plates[u] ~= nil end
    C_NamePlate = { GetNamePlateForUnit = function(u) return plates[u] and CreateFrame("Frame") end }
    local marryk
    for _, p in ipairs(FG.Nearby:Around(0, 299.3, 712)) do
        if p.npc == 944 then marryk = p end
    end
    assert(marryk, "the place knows its NPC")
    -- Out of reach for the arrival test: far from the character.
    marryk.x = 40
    FG.Guide:PointToPlace(marryk)
    assert(FG.NpcMark:Unit() == "nameplate3", "marked on his nameplate")
    plates.nameplate3 = nil
    fire("NAME_PLATE_UNIT_REMOVED", "nameplate3")
    assert(FG.NpcMark:Unit() == nil, "gone with it")
    plates.nameplate3 = "Creature-0-1-2-3-944-0000"
    fire("NAME_PLATE_UNIT_ADDED", "nameplate3")
    assert(FG.NpcMark:Unit() == "nameplate3", "back with it")
    FG.Guide:PointToStep(1)
    assert(FG.NpcMark:Unit() == nil, "another target: no mark")
    UnitGUID, UnitExists, C_NamePlate = realGUID, realExists, nil
    FG.Nearby:Forget()
end
print("npc mark ok")

-- The arrow (off by default): the chevron's frame for a turn (64 frames, 8 a row, counter-
-- clockwise), on the guide's place when turned on.
do
    local f, left, right, top, bottom = FG.Arrow.Frame(0)
    assert(f == 0 and left == 0 and right == 0.125 and top == 0 and bottom == 0.125, "straight ahead: the first")
    f, left, _, top = FG.Arrow.Frame(math.pi / 2)
    assert(f == 16 and left == 0 and top == 0.25, "a quarter turn left: the third row")
    assert(FG.Arrow.Frame(2 * math.pi - 0.01) == 0, "almost a full turn: ahead again")
    assert(FG.Arrow:Target() == nil, "off by default")
    FG:Set("arrowShown", true)
    local t = FG.Arrow:Target()
    assert(t and t.m == 1426 and t.x == 40, "on the guide's place")
    FG:Set("arrowShown", nil)
    assert(FG.Arrow:Target() == nil, "off again")
end
print("arrow ok")

-- The quest panel: one line a quest in both modes; folded, no line.
local logEntries, logInfo = C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo
C_QuestLog.GetNumQuestLogEntries = function() return 6 end
C_QuestLog.GetInfo = function(i) return { questID = 8100 + i, title = "Quest " .. i, level = 1 } end
FG:Set("trackerAll", true)
FG.Tracker:Refresh()
assert(#FG.Tracker.shown == 6 and FG.Tracker.lines == 6, "a line a quest, got " .. FG.Tracker.lines)
-- A click on a quest makes the game track it, as from the game's own tracker.
for _, f in ipairs(frames) do
    if rawget(f, "questID") == 8102 and f._shown then
        f:GetScript("OnClick")(f, "LeftButton")
        break
    end
end
assert(C_SuperTrack.quest == 8102, "the clicked quest tracked by the game: " .. tostring(C_SuperTrack.quest))
FG:Save("guideMode", "minimal")
FG.Tracker:Refresh()
assert(FG.Tracker.lines == 6, "the same with the minimal guide")
FG:Save("guideMode", nil)
-- The guide's button hides the whole panel (kept), the bank shows it while open.
FG.Tracker:Toggle()
FG.Tracker:Refresh()
assert(not FG.Tracker.visible and PathwrightDB.settings.questPanel == false, "hidden by the guide's button")
FG.Tracker:ShowItems(true)
assert(FG.Tracker.visible, "shown at the bank")
FG.Tracker:ShowItems(false)
assert(not FG.Tracker.visible, "hidden again after the bank")
FG.Tracker:Toggle()
FG.Tracker:Refresh()
assert(FG.Tracker.visible, "shown again")
FG:Set("trackerAll", false)
C_QuestLog.GetNumQuestLogEntries, C_QuestLog.GetInfo = logEntries, logInfo
print("quest panel ok")

-- The windows' size: Ctrl + mouse wheel only, the wheel alone is the camera's.
local scaleBefore = FG:Get("scale")
IsControlKeyDown = function() return false end
FG.Card:Frame():OnMouseWheel(1)
assert(FG:Get("scale") == scaleBefore, "the wheel alone does not resize")
IsControlKeyDown = function() return true end
FG.Card:Frame():OnMouseWheel(1)
assert(FG:Get("scale") > scaleBefore, "Ctrl + wheel resizes")
FG:Save("scale", nil)
print("window size ok")

-- Items to keep: the common items of the quests not turned in yet (not quest items), in the bags
-- and the bank; the bank is read when opened, an item can be marked by hand as being there.
FG.Routes["keep-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1,
    steps = {
        { k = "accept", t = "Accept Cloth", q = 9001, id = 1, m = 1426, x = 29.93, y = 71.2, lvl = 1 },
        {
            k = "objective",
            t = "Linen Cloth x10",
            q = 9001,
            o = 1,
            e = "item",
            id = 2589,
            n = "Linen Cloth",
            c = 10,
            lvl = 1,
        },
        { k = "objective", t = "Wolf Meat x8", q = 9001, o = 2, e = "item", id = 750, n = "Wolf Meat", lvl = 1 },
        { k = "turnin", t = "Turn in Cloth", q = 9001, id = 1, m = 1426, x = 29.93, y = 71.2, lvl = 1 },
        { k = "grind", t = "Grind", lvl = 60 },
    },
}
itemClasses[2589] = 7
onQuest[9001] = true
useRoute("keep-test")
local keep = FG.Bank:Items()
assert(#keep == 1 and keep[1].id == 2589 and keep[1].need == 10, "the cloth, not the quest item")
bags[2589], bank[2589] = 4, 6
assert(FG.Bank:Items()[1].bags == 4 and FG.Bank:Items()[1].bank == nil, "the bank not seen yet")
FG.Bank:ToggleMark(2589)
assert(FG.Bank:Items()[1].marked, "marked by hand as in the bank")
fire("BANKFRAME_OPENED")
local atBank = FG.Bank:Items()[1]
assert(atBank.bank == 6 and not atBank.marked, "the bank read, the mark no longer needed")
assert(atBank.hint == "take", "needed soon: to take")
FG.Tracker:Refresh()
assert(FG.Tracker.tab == "items", "the bank shows the items tab")
fire("BANKFRAME_CLOSED")
FG.Tracker:Refresh()
assert(FG.Tracker.tab == "quests" and FG.Bank:Items()[1].hint == nil, "back to the quests")
-- An item needed much later shows once owned (or when all are asked for).
UnitLevel = function() return 1 end
FG.Routes["keep-test"].steps[3] =
    { k = "objective", t = "Silk x4", q = 9001, o = 2, e = "item", id = 4306, n = "Silk", c = 4, lvl = 20 }
itemClasses[4306] = 7
useRoute("keep-test")
local shownNow, later = FG.Bank:Items()
assert(#shownNow == 1 and later == 1, "the silk needed at 20 waits")
assert(#FG.Bank:Items(true) == 2, "all of them when asked")
bags[4306] = 2
assert(#FG.Bank:Items() == 2, "owned: shown")
bags[4306] = nil
UnitLevel = function() return playerLevel end
completed[9001], onQuest[9001] = true, nil
assert(#FG.Bank:Items(true) == 0, "turned in: nothing to keep")
-- Before the Profile addon made the character's saved data (early tracker refresh): nothing, no error.
do
    local realCharacters = PathwrightDB.characters
    PathwrightDB.characters = {}
    local none, later = FG.Bank:Items(true)
    assert(#none == 0 and later == 0, "no character data yet: no item")
    FG.Bank:ToggleMark(2589)
    PathwrightDB.characters = realCharacters
end
completed[9001], bags[2589], bank[2589] = nil, nil, nil
print("items to keep ok")

-- Gone back to a step already done: the minimal strip still shows it, marked done.
onQuest[9001] = true
FG:Save("guideMode", "minimal")
useRoute("keep-test")
FG.Guide:Go(1)
local strip = FG.Mini:Frame()
assert(strip.name:GetText() == "Accept Cloth", "the step gone back to: " .. tostring(strip.name:GetText()))
assert(strip.verb:GetText():find("faite", 1, true), "marked done: " .. strip.verb:GetText())
FG:Save("guideMode", nil)
onQuest[9001] = nil
print("minimal strip on a done step ok")

do
    -- A step done with mobs to kill on the way to it: their line stays, greyed with it (the XP
    -- bar's box still holds their XP).
    FG.Routes["farm-done-test"] = {
        race = 7,
        class = 8,
        faction = "Alliance",
        fromLevel = 1,
        toLevel = 60,
        time = 1,
        steps = {
            { k = "accept", t = "Accept A", q = 9111, id = 1, m = 1426, x = 10, y = 10, lvl = 1, fk = 10, fx = 2093 },
            { k = "grind", t = "Grind", lvl = 60 },
        },
    }
    onQuest[9111] = true
    useRoute("farm-done-test")
    FG.Guide:Go(1)
    local farmRow = FG.Guide.view.tasks[1]
    assert(farmRow.kind == "farm" and farmRow.done, "the mobs on the way, listed as done")
    assert(farmRow.count == "~2,093 XP", "their planned XP: " .. farmRow.count)
    assert(FG.Guide.view.tasks[2].index == 1 and FG.Guide.view.tasks[2].done, "then the step, done")
    onQuest[9111] = nil
    print("mobs on the way of a done step ok")
end

-- The next steps show those done already (greyed), not hidden.
FG.Routes["next-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1,
    steps = {
        { k = "accept", t = "Accept A", q = 9101, id = 1, m = 1426, x = 10, y = 10, lvl = 1 },
        { k = "accept", t = "Accept B", q = 9102, id = 2, m = 1426, x = 50, y = 50, lvl = 1 },
        { k = "accept", t = "Accept C", q = 9103, id = 3, m = 1426, x = 60, y = 60, lvl = 1 },
        { k = "grind", t = "Grind", lvl = 60 },
    },
}
onQuest[9102] = true
useRoute("next-test")
local nextSteps = {}
for _, v in ipairs(FG.Guide.view.next) do
    if v.index then nextSteps[v.index] = v end
end
assert(nextSteps[2] and nextSteps[2].done, "B, done already, listed as done")
assert(nextSteps[3] and not nextSteps[3].done, "C to do")
onQuest[9102] = nil
print("done next steps ok")

-- Pages: two objectives close together are one page, kept until both are done; the turn-in of
-- their quest, elsewhere, is the next page and does not show them again (its progress instead).
FG.Routes["page-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1,
    steps = {
        {
            k = "objective",
            t = "Kill Black Ravager",
            n = "Black Ravager",
            q = 9201,
            o = 1,
            id = 11,
            m = 1431,
            x = 66.8,
            y = 30.5,
            lvl = 1,
        },
        {
            k = "objective",
            t = "Kill Young Black Ravager",
            n = "Young Black Ravager",
            q = 9201,
            o = 2,
            id = 12,
            m = 1431,
            x = 68.3,
            y = 28.3,
            lvl = 1,
        },
        { k = "turnin", t = "Turn in Ira's Dagger", q = 9201, id = 13, m = 1431, x = 75, y = 45, lvl = 1 },
        { k = "grind", t = "Grind", lvl = 60 },
    },
}
local ravagers = {
    { text = "Black Ravager slain: 0/10", numFulfilled = 0, numRequired = 10, finished = false },
    { text = "Young Black Ravager slain: 0/10", numFulfilled = 0, numRequired = 10, finished = false },
}
local pageObjectives = C_QuestLog.GetQuestObjectives
C_QuestLog.GetQuestObjectives = function(q) return q == 9201 and ravagers or pageObjectives(q) end
onQuest[9201] = true
useRoute("page-test")
local function page()
    local out = {}
    for _, v in ipairs(FG.Guide.view.tasks) do
        table.insert(out, v.index)
    end
    return table.concat(out, ",")
end
assert(page() == "1,2", "the two objectives together: " .. page())
ravagers[1].numFulfilled, ravagers[1].finished = 10, true
fire("QUEST_LOG_UPDATE")
runTimers()
assert(page() == "1,2" and char.guide.step == 2, "the page stays until both are done: " .. page())
Press("next")
assert(page() == "3", "the turn-in alone, not its objectives again: " .. page())
local turnin = FG.Guide.view.tasks[1]
assert(turnin.have == 10 and turnin.need == 20, "the turn-in shows how far the quest is")
Press("prev")
assert(page() == "1,2", "back to the objectives' page: " .. page())
C_QuestLog.GetQuestObjectives = pageObjectives
onQuest[9201] = nil
print("pages ok")

-- Objectives whose names hold one another: "Night Web Spider" is not "Young Night Web Spider",
-- whichever comes first in the log and whatever the text's form (Forever's or Classic's).
FG.Routes["spider-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1,
    steps = {
        {
            k = "objective",
            t = "Kill Young Night Web Spider x10",
            n = "Young Night Web Spider",
            q = 9301,
            o = 1,
            e = "npc",
            id = 1504,
            m = 1431,
            x = 28.6,
            y = 57.7,
            lvl = 1,
        },
        {
            k = "objective",
            t = "Kill Night Web Spider x8",
            n = "Night Web Spider",
            q = 9301,
            o = 2,
            e = "npc",
            id = 1505,
            m = 1431,
            x = 24.8,
            y = 59.7,
            lvl = 1,
        },
        { k = "turnin", t = "Turn in Night Web's Hollow", q = 9301, id = 13, m = 1431, x = 32, y = 66, lvl = 1 },
        { k = "grind", t = "Grind", lvl = 60 },
    },
}
for _, texts in ipairs({
    { "10/10 Young Night Web Spider slain", "2/8 Night Web Spider slain", young = 1 },
    { "Young Night Web Spider slain: 10/10", "Night Web Spider slain: 2/8", young = 1 },
    { "2/8 Night Web Spider slain", "10/10 Young Night Web Spider slain", young = 2 },
}) do
    local spiders = {}
    for i, text in ipairs(texts) do
        local young = i == texts.young
        spiders[i] = {
            text = text,
            numFulfilled = young and 10 or 2,
            numRequired = young and 10 or 8,
            finished = young,
        }
    end
    C_QuestLog.GetQuestObjectives = function(q) return q == 9301 and spiders or pageObjectives(q) end
    onQuest[9301] = true
    useRoute("spider-test")
    FG.Guide:Resync()
    assert(char.guide.step == 2, "the older spiders still to kill (" .. texts[1] .. "), step " .. char.guide.step)
    -- On one page with the young ones (the same hollow).
    local task
    for _, v in ipairs(FG.Guide.view.tasks) do
        if v.index == 2 then task = v end
    end
    assert(task.have == 2 and task.need == 8, "their own count: " .. tostring(task.have) .. "/" .. tostring(task.need))
end
C_QuestLog.GetQuestObjectives = pageObjectives
onQuest[9301] = nil
print("objectives by name ok")

-- Texts: in the language chosen in the settings, else the game's; English without a
-- translation; Mexican Spanish as Spain's.
assert(FG.T("Accept") == "Prendre", "the game's language: " .. FG.T("Accept"))
FG:Save("locale", "deDE")
assert(FG.T("Accept") == "Annehmen" and FG.T("No such text") == "No such text", "the chosen language")
FG:Save("locale", "esMX")
assert(FG.T("Accept") == "Aceptar", "Mexican Spanish")
FG:Save("locale", "enUS")
assert(FG.T("Accept") == "Accept", "English")
FG:Save("locale", "xxXX")
assert(FG.T("Accept") == "Prendre", "an unknown language: the game's")
FG:Save("locale", nil)
print("languages ok")

-- The tracker lists the guide's quests in progress even when the quest log lists none
-- (headers collapsed in the quest log window).
FG.Routes["tracker-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1,
    steps = {
        { k = "accept", t = "Accept Logged", q = 7101, lvl = 1 },
        { k = "turnin", t = "Turn in Logged", q = 7101, lvl = 1 },
        { k = "grind", t = "Grind", lvl = 60 },
    },
}
useRoute("tracker-test")
onQuest[7101] = true
local entries = C_QuestLog.GetNumQuestLogEntries
C_QuestLog.GetNumQuestLogEntries = function() return 0 end
FG.Tracker:Refresh()
assert(FG.Tracker.shown[1] == 7101, "guide quest listed without the log")
C_QuestLog.GetNumQuestLogEntries = entries
onQuest[7101] = nil
print("tracker from the guide ok")

-- During combat, a box made protected by a secure button hanging on it (a quest item button)
-- keeps its size: the game would block the change. Resized after the fight.
local box = FG.Guide:Box()
local resized = false
box.SetHeight = function() resized = true end
box.IsProtected = function() return true end
InCombatLockdown = function() return true end
FG.Guide:Refresh()
assert(not resized, "a protected box resized during combat")
InCombatLockdown = function() return false end
fire("PLAYER_REGEN_ENABLED")
assert(resized, "resized after the fight")
print("combat layout ok")

-- Every window moves when dragged from anywhere on it, its rows and buttons too (GitHub #1); where
-- it was dropped is saved. Nothing moves while the windows are locked, nor a window the game
-- protects during combat. A click on a row still acts, not the release that ends a drag.
local function named(name)
    for _, f in ipairs(frames) do
        if f:GetName() == name then return f end
    end
end
local function childOf(window, test)
    for _, f in ipairs(frames) do
        local p = rawget(f, "_parent")
        while type(p) == "table" and p ~= window do
            p = rawget(p, "_parent")
        end
        if p == window and rawget(f, "OnDragStart") and test(f) then return f end
    end
end
local function watchMoves(window)
    local d = { moves = 0 }
    window.StartMoving = function() d.moves = d.moves + 1 end
    window.StopMovingOrSizing = function() d.stops = (d.stops or 0) + 1 end
    window.GetLeft = function() return 120 end
    window.GetTop = function() return 640 end
    window.GetPoint = function() return "TOPLEFT", UIParent, "BOTTOMLEFT", 120, 640 end
    return d
end
local function drag(handle)
    handle.OnDragStart(handle, "LeftButton")
    handle.OnDragStop(handle)
end
do
    local strip = named("PathwrightToolstrip")
    local motion = watchMoves(strip)
    local anchor
    strip.SetPoint = function(_, ...) anchor = { ... } end
    local state = FG.Guide:State()
    state.toolstripPoint = { "BOTTOM", "UIParent", "BOTTOM", 80, 140 }
    FG.Toolstrip:Refresh()
    assert(anchor[1] == "BOTTOMLEFT" and anchor[2] == FG.Card:Frame() and anchor[3] == "TOPLEFT" and anchor[5] == 6)
    drag(strip)
    assert(motion.moves == 0, "the docked toolstrip stays on the guide")
    Option("Pathwright_toolstripUnlocked"):SetValue(true)
    assert(anchor[4] == 80 and anchor[5] == 140, "unlock restores a previously saved position")
    drag(strip)
    assert(motion.moves == 1 and state.toolstripPoint[4] == 120, "unlocked drag saves the new position")
    InCombatLockdown = function() return true end
    FG:Save("toolstripUnlocked", false)
    assert(anchor[2] == UIParent and FG.Toolstrip.pending, "redocking waits for combat to end")
    InCombatLockdown = function() return false end
    fire("PLAYER_REGEN_ENABLED")
    assert(anchor[2] == FG.Card:Frame(), "redocked after combat")
    Press("mode")
    assert(anchor[2] == FG.Mini:Frame() and anchor[5] > 6, "the strip clears the minimal guide header")
    Press("mode")
    FG:Save("toolstripUnlocked", true)
    assert(anchor[4] == 120 and anchor[5] == 640, "unlock restores the last drag")
    FG.Toolstrip:ResetPosition()
    assert(anchor[2] == FG.Card:Frame() and not state.toolstripPoint, "reset returns above the guide")
    FG:Save("toolstripUnlocked", nil)
    strip.SetPoint = nil
end
do
    FG.Stats:ToggleBoard()
    local board = FG.Stats.board
    local motion = watchMoves(board)
    drag(board)
    assert(motion.moves == 1 and motion.stops == 1, "the leaderboard can be dropped without a position callback")
    board:Hide()
end
local realDragTime = GetTime
local dragNow = 100
GetTime = function() return dragNow end
local pointed
local realPointToStep = FG.Guide.PointToStep
FG.Guide.PointToStep = function(_, index) pointed = index end

local card = FG.Card:Frame()
local cardMoves = watchMoves(card)
local stepRow = card.rows[1]
assert(stepRow and stepRow.index and stepRow.OnDragStart, "the card's first step row passes drags on")
FG.Guide:State().point = nil
drag(stepRow)
local saved = FG.Guide:State().point
assert(cardMoves.moves == 1 and cardMoves.stops == 1, "dragging a step row moves the card")
assert(saved and saved[1] == "TOPLEFT" and saved[4] == 120 and saved[5] == 640, "the card's place saved")
pointed = nil
stepRow.OnClick(stepRow, "LeftButton")
assert(pointed == nil, "the release ending the drag is no click")
dragNow = dragNow + 1
stepRow.OnClick(stepRow, "LeftButton")
assert(pointed == stepRow.index, "a click on the row still points at its step")
assert(rawget(stepRow, "OnEnter"), "the row keeps its tooltip")
FG:Set("lockFrames", true)
FG.Guide:State().point = nil
drag(stepRow)
drag(card)
assert(cardMoves.moves == 1 and FG.Guide:State().point == nil, "locked windows do not move")
FG:Set("lockFrames", nil)
drag(card)
assert(cardMoves.moves == 2, "the card itself still moves")

-- The quest panel: its lines move it; protected by its secure quest item buttons, not in combat.
local tracker = named("PathwrightTracker")
local trackerMoves = watchMoves(tracker)
local trackerLine = childOf(tracker, function(f) return rawget(f, "track") ~= nil end)
assert(trackerLine, "the quest panel's lines pass drags on")
local secureItem = named("PathwrightItemButton1")
assert(not secureItem or not rawget(secureItem, "OnDragStart"), "secure quest item buttons left alone")
FG.Guide:Layout().trackerPoint = nil
drag(trackerLine)
assert(trackerMoves.moves == 1, "dragging a quest line moves the quest panel")
assert(FG.Guide:Layout().trackerPoint and FG.Guide:Layout().trackerPoint[4] == 120, "the quest panel's place saved")
tracker.IsProtected = function() return true end
InCombatLockdown = function() return true end
drag(trackerLine)
assert(trackerMoves.moves == 1, "a protected window does not move during combat")
InCombatLockdown = function() return false end
drag(trackerLine)
assert(trackerMoves.moves == 2, "it moves again after the fight")
tracker.IsProtected = nil
FG.Guide:Layout().trackerPoint = nil
tracker.placed = nil
FG.Tracker:Refresh()

-- A line that inherited the quest item buttons' protection (the newer clients): in combat it keeps
-- its place and visibility, its texts still change; all of it back once the fight ends.
do
    local frozenLine = childOf(tracker, function(f) return rawget(f, "track") ~= nil end)
    local frozenMoves = 0
    local realClear = frozenLine.ClearAllPoints
    frozenLine.ClearAllPoints = function() frozenMoves = frozenMoves + 1 end
    frozenLine.IsProtected = function() return true end
    frozenLine:Hide()
    InCombatLockdown = function() return true end
    FG.Tracker:Refresh()
    assert(frozenMoves == 0, "a protected line is not moved during combat")
    assert(not frozenLine._shown, "nor shown in combat")
    InCombatLockdown = function() return false end
    FG.Tracker:Refresh()
    assert(frozenMoves > 0 and frozenLine._shown, "placed and shown again after the fight: " .. frozenMoves)
    frozenLine.IsProtected = nil
    frozenLine.ClearAllPoints = realClear
end

-- The minimal guide: its strip, the next steps under it and the compass over it move the strip.
Press("mode")
local strip = FG.Mini:Frame()
local stripMoves = watchMoves(strip)
local drop = named("PathwrightMiniNext")
local dropRow = childOf(drop, function(f) return rawget(f, "dot") ~= nil end)
assert(dropRow, "the next steps under the strip pass drags on")
FG.Guide:State().miniPoint = nil
drag(dropRow)
assert(stripMoves.moves == 1, "dragging the next steps moves the strip")
assert(FG.Guide:State().miniPoint and FG.Guide:State().miniPoint[4] == 120, "the strip's place saved")
pointed = nil
strip.OnMouseUp(strip, "LeftButton")
assert(pointed == nil, "dropping the strip does not point at its step")
dragNow = dragNow + 1
strip.OnMouseUp(strip, "LeftButton")
assert(pointed ~= nil and pointed == strip.index, "a click on the strip still points at its step")
local compass = named("PathwrightCompass")
local compassMoves = watchMoves(compass)
drag(compass)
assert(stripMoves.moves == 2 and compassMoves.moves == 0, "the compass over the strip moves the strip")
Press("mode")
drag(compass)
assert(compassMoves.moves == 1, "on its own, the compass moves itself")
local compassPoint = FG.Guide:Layout().compassPoint
assert(compassPoint and compassPoint[4] == 120, "the compass's place saved")
FG.Guide:Layout().compassPoint, FG.Guide:State().miniPoint = nil, nil
FG.Guide.PointToStep = realPointToStep
GetTime = realDragTime
print("drag anywhere ok")

-- The compass: its ends dragged change its width (its middle stays), Ctrl + wheel its own size,
-- kept for the character; a hint on the bar says how; "Compass back to the top" puts it
-- back; "Lock the windows" locks the windows.
do
    local state = FG.Guide:Layout()
    compass.GetEffectiveScale = function() return 1 end
    compass.GetCenter = function() return 500, 700 end
    compass.SetWidth = function(self, w) self.width = w end
    compass.ClearAllPoints = function(self) self.points = {} end
    compass.SetPoint = function(self, ...) table.insert(self.points, { ... }) end
    compass.GetPoint = function(self) return unpack(self.points[1]) end
    compass.SetScale = function(self, s) self.scale = s end
    local cursor = 100
    local realCursor = GetCursorPosition
    GetCursorPosition = function() return cursor, 0 end
    local left, right = compass.grips[1], compass.grips[2]
    local function widen(grip, dx)
        cursor = 100
        grip.OnMouseDown(grip, "LeftButton")
        cursor = 100 + dx
        if rawget(grip, "OnUpdate") then grip.OnUpdate(grip, 0.03) end
        grip.OnMouseUp(grip, "LeftButton")
    end
    widen(right, 50)
    assert(compass.width == 520 and state.compassWidth == 520, "the right end dragged out: wider on both sides")
    local p = state.compassPoint
    assert(p and p[1] == "CENTER" and p[4] == 500 and p[5] == 700, "its middle stays where it was")
    widen(left, 30)
    assert(state.compassWidth == 460, "the left end dragged in: narrower")
    widen(left, 10000)
    assert(state.compassWidth == 240 and compass.width == 240, "not narrower than its least width")
    FG:Set("lockFrames", true)
    widen(right, 50)
    assert(compass.width == 240, "locked: its ends do not move")
    FG:Set("lockFrames", nil)
    assert(rawget(right, "OnUpdate") == nil, "no sizing left running")

    -- Ctrl + wheel over it: its own size, not the other windows'.
    local windows = FG:Get("scale")
    IsControlKeyDown = function() return false end
    compass.OnMouseWheel(compass, 1)
    assert(state.compassScale == nil, "the wheel alone is the camera's")
    IsControlKeyDown = function() return true end
    compass.OnMouseWheel(compass, 1)
    compass.OnMouseWheel(compass, 1)
    assert(state.compassScale == 1.1 and FG:Get("scale") == windows, "Ctrl + wheel: the compass alone grows")
    assert(math.abs(compass.scale - windows * 1.1) < 1e-9, "its size on top of the windows' size")
    IsControlKeyDown = function() return false end

    -- The hint on the bar.
    local lines = {}
    GameTooltip.AddLine = function(_, text) table.insert(lines, text) end
    local function hint()
        lines = {}
        compass.OnEnter(compass)
        return table.concat(lines, "\n")
    end
    assert(
        hint():find("Glisser : la déplacer", 1, true) and hint():find("Ctrl + molette", 1, true),
        "the hint says how"
    )
    Press("lock")
    assert(FG:Get("lockFrames") == true and PathwrightDB.settings.lockFrames == true, "lock button: kept")
    assert(
        hint():find("Verrouillée", 1, true) and not hint():find("Glisser : la déplacer", 1, true),
        "locked: the hint says so"
    )
    local moves = compassMoves.moves
    drag(compass)
    assert(compassMoves.moves == moves, "locked: it does not move")
    Press("lock")
    assert(FG:Get("lockFrames") == false, "lock button again: unlocked")
    FG:Save("lockFrames", nil)
    GameTooltip.AddLine = nil

    -- Back at the top, at its first size.
    Press("compassReset")
    assert(state.compassPoint == nil and state.compassWidth == nil and state.compassScale == nil, "reset: forgotten")
    assert(compass.width == 420 and math.abs(compass.scale - windows) < 1e-9, "reset: its first width and size")
    p = compass.points[1]
    assert(p and p[1] == "TOP" and p[5] == -14, "reset: at the top of the screen")

    -- Each mode keeps its own: widened in the full guide, the compass over the strip is not.
    widen(right, 50)
    assert(compass.width == 520, "full guide: widened")
    Press("mode")
    assert(compass.width == 420 and FG.Guide:Layout().compassWidth == nil, "minimal guide: its own width")
    widen(right, -50)
    assert(compass.width == 320 and FG.Guide:Layout().compassWidth == 320, "minimal guide: narrowed")
    Press("mode")
    assert(compass.width == 520 and state.compassWidth == 520, "full guide: its width back")
    Press("compassReset")
    GetCursorPosition = realCursor
end
print("compass layout ok")

-- Places kept for both modes by older versions: the compass's with the full guide, the others with
-- the mode shown.
do
    local guide = FG.Guide:State()
    local saved = guide.layout
    guide.layout = nil
    guide.trackerPoint = { "TOPLEFT", "UIParent", "TOPLEFT", 10, -10 }
    guide.compassWidth, guide.compassPoint = 300, { "TOP", "UIParent", "TOP", 0, -30 }
    FG:Save("guideMode", "minimal")
    local minimal = FG.Guide:Layout()
    assert(minimal.trackerPoint[4] == 10 and minimal.compassWidth == 300, "old places: the mode shown")
    assert(guide.layout.full.compassPoint[5] == -30, "old compass place: the full guide's")
    assert(guide.trackerPoint == nil and guide.compassWidth == nil and guide.compassPoint == nil, "moved once")
    FG:Save("guideMode", nil)
    assert(FG.Guide:Layout().trackerPoint == nil, "the full guide's panel at its first place")
    guide.layout = saved
end
print("layout per mode ok")

-- "Hide the addon's windows" (`/pw`) hides every window and mark of the addon at once (one parent
-- frame), for the session; clicked again it brings them back as they were. Progress and settings
-- are kept.
FG.Routes["visibility-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1,
    steps = {
        { k = "accept", t = "Accept Logged", q = 7101, lvl = 1, m = 1426, x = 45, y = 50 },
        { k = "grind", t = "Grind", lvl = 60, m = 1426, x = 46, y = 51 },
    },
}
useRoute("visibility-test")
local root = FG.UIRoot
local stepBeforeHide = char.guide.step
local originalSetShown = root.SetShown
local visibilityWrites = 0
root.SetShown = function(self, shown)
    assert(not InCombatLockdown(), "the addon's parent frame changed during combat")
    visibilityWrites = visibilityWrites + 1
    originalSetShown(self, shown)
end
local oldItemInfo, oldQuestIndex = GetQuestLogSpecialItemInfo, GetQuestLogIndexByID
GetQuestLogIndexByID = function() return 1 end
GetQuestLogSpecialItemInfo = function() return "item:123", 123 end
FG.Toolstrip:SetSteps({ { q = 7101 } })
GetQuestLogSpecialItemInfo, GetQuestLogIndexByID = oldItemInfo, oldQuestIndex
-- The quest's own item where the game names none: the one the quest hands out (QuestItems.lua),
-- when it is carried and can be used. On a client without GetQuestLogIndexByID too.
do
    local realIndex, realFind, realItems = GetQuestLogIndexByID, C_QuestLog.GetLogIndexForQuestID, FG.QuestItems
    local realCount, realInfo, realSpell = FG.ItemCount, FG.ItemInfo, GetItemSpell
    GetQuestLogIndexByID = nil
    C_QuestLog.GetLogIndexForQuestID = function(q) return (q == 1534 or q == 1535) and 4 or nil end
    FG.QuestItems = { [1534] = 7767, [1535] = 7768, [1536] = 7769 }
    local carried = { [7767] = 1, [7768] = 1, [7769] = 1 }
    FG.ItemCount = function(id) return carried[id] or 0 end
    FG.ItemInfo = function(id) return "Item " .. tostring(id), nil, nil, nil, nil, nil, nil, nil, nil, 134 end
    GetItemSpell = function(id) return id == 7767 and "Fill Waterskin" or nil end
    local actions = FG.Toolstrip.Actions({ { k = "objective", q = 1534, ic = "use" } })
    assert(actions[1] and actions[1].kind == "item" and actions[1].link == "item:7767", "the quest's item to use")
    assert(actions[1].name == "Item 7767" and actions[1].texture == 134, "its name and icon")
    assert(#FG.Toolstrip.Actions({ { q = 1535 } }) == 0, "an item that cannot be used is not offered")
    assert(#FG.Toolstrip.Actions({ { q = 1536 } }) == 0, "nor the item of a quest not in the log")
    carried[7767] = 0
    assert(#FG.Toolstrip.Actions({ { q = 1534 } }) == 0, "nor one not carried")
    GetQuestLogIndexByID, C_QuestLog.GetLogIndexForQuestID, FG.QuestItems = realIndex, realFind, realItems
    FG.ItemCount, FG.ItemInfo, GetItemSpell = realCount, realInfo, realSpell
    print("toolstrip quest item ok")
end
local owned = {}
for _, f in ipairs(frames) do
    if f:GetParent() == root and f:GetName() then owned[f:GetName()] = f end
end
for _, name in ipairs({
    "PathwrightTodo",
    "PathwrightMini",
    "PathwrightButtons",
    "PathwrightCompass",
    "PathwrightTracker",
    "PathwrightToolstrip",
}) do
    assert(owned[name], name .. " hangs on the addon's parent frame")
end
assert(FG.Card:Frame():IsVisible(), "the guide visible before hiding")
local popupHidden
StaticPopup_Hide = function(which) popupHidden = which end
Press("hide")
assert(not root:IsShown() and not FG:Get("uiShown"), "hidden")
assert(popupHidden == "PATHWRIGHT_RESET", "the guide's reset dialog closed")
FG.Guide:Refresh()
FG.Tracker:Refresh()
FG.Talents:Refresh()
for _, f in pairs(owned) do
    assert(not f:IsVisible(), "a refresh does not bring back " .. f:GetName())
end
assert(FG:Get("guideShown") and FG:Get("questPanel") and FG:Get("guideMode") == "full", "settings kept")
assert(char.guide.step == stepBeforeHide, "progress kept")
assert(PathwrightDB.settings.uiShown == nil, "hidden for the session only")
Press("hide")
assert(root:IsShown() and FG:Get("uiShown"), "shown again")
assert(FG.Card:Frame():IsVisible(), "the guide back")
-- "Hide the guide" stays the guide's own switch: shown again with the rest, it stays hidden.
Press("guide")
Press("hide")
Press("hide")
assert(not FG:Get("guideShown") and root:IsShown(), "the guide alone still hidden")
assert(not FG.Card:Frame():IsShown(), "the guide's card stays hidden")
Press("guide")
assert(FG.Card:Frame():IsVisible(), "the guide back")

-- In combat (the quest item buttons are secure), the change waits for the end of the fight; the
-- button says what comes, the last click wins.
InCombatLockdown = function() return true end
local writesBeforeCombat = visibilityWrites
Press("hide")
assert(root:IsShown() and FG:Get("uiShown"), "hide waits during combat")
assert(visibilityWrites == writesBeforeCombat, "nothing changed during combat")
assert(not FG:UIWanted(), "hidden after the fight")
InCombatLockdown = function() return false end
fire("PLAYER_REGEN_ENABLED")
assert(not root:IsShown(), "hidden after the fight")
InCombatLockdown = function() return true end
Press("hide")
Press("hide")
InCombatLockdown = function() return false end
fire("PLAYER_REGEN_ENABLED")
assert(not root:IsShown(), "the last click wins")
InCombatLockdown = function() return true end
Press("hide")
assert(not root:IsShown(), "show waits during combat")
InCombatLockdown = function() return false end
fire("PLAYER_REGEN_ENABLED")
assert(root:IsShown(), "shown after the fight")
fire("PLAYER_REGEN_ENABLED")
assert(root:IsShown(), "nothing pending any more")
root.SetShown = originalSetShown

-- The world map's pins and the game's waypoint go at once and stay away on later refreshes.
-- `pins`: the steps' pins (the walk's dots have their own template).
local provider, pins = nil, 0
WorldMapFrame = {
    AddDataProvider = function(self, p)
        provider = provider or p
        p.GetMap = function() return self end
    end,
    IsShown = function() return true end,
    RemoveAllPinsByTemplate = function(_, template)
        if template == "PWStepPinTemplate" then pins = 0 end
    end,
    GetMapID = function() return 1426 end,
    AcquirePin = function(_, template)
        if template == "PWStepPinTemplate" then pins = pins + 1 end
    end,
}
FG.MapPins:Refresh()
assert(pins > 0 and waypoint, "map pins and waypoint shown")
Press("hide")
assert(not waypoint, "the waypoint cleared on hide")
FG.Guide:Refresh()
assert(not waypoint, "a refresh does not set the waypoint again while hidden")
assert(pins == 0, "map pins removed on hide")
provider:RefreshAllData()
assert(pins == 0, "a map refresh adds no pin while hidden")

-- An NPC's walking path (`path`) is placed on the step's own map; none without it.
do
    local pts = FG.MapPins.PathOn({ m = 1412, path = { 50, 60, 55, 64 } }, 1412)
    assert(pts and #pts == 4 and pts[1] == 0.5 and pts[4] == 0.64, "the path on its map")
    assert(FG.MapPins.PathOn({ m = 1412, x = 1, y = 1 }, 1412) == nil, "no path, no line")
    assert(FG.MapPins.PathOn({ m = 1412, path = { 50, 60 } }, 1412) == nil, "one point is no line")
    local found, register = nil, FG.Builtin.Register
    FG.Builtin.Register = function(def)
        for _, s in ipairs(def.steps) do
            if not found and s.id == 2988 and s.k == "accept" then found = s end
        end
    end
    assert(loadfile("addon/Pathwright_Guide/Builtin/TaurenStarter113.lua"))()
    FG.Builtin.Register = register
    assert(found and found.path and #found.path >= 4 and #found.path % 2 == 0, "Morin's path in the guide data")
end

-- The path's lines are drawn on the map canvas, reused, and hidden again; the game calls
-- `RefreshAllData` itself, outside `FG:Try`, so the drawing code must run here from start to finish.
do
    local lines, created = {}, 0
    local function LineStub()
        local l = { shown = false }
        function l:SetThickness() end
        function l:SetColorTexture() end
        function l:SetStartPoint() end
        function l:SetEndPoint() end
        function l:Show() self.shown = true end
        function l:Hide() self.shown = false end
        return l
    end
    local function FrameStub()
        local f = {}
        function f:GetWidth() return 1000 end
        function f:GetHeight() return 500 end
        function f:GetFrameLevel() return 3 end
        function f:SetFrameLevel() end
        function f:SetAllPoints() end
        function f:SetParent() end
        function f:CreateLine()
            created = created + 1
            local l = LineStub()
            lines[#lines + 1] = l
            return l
        end
        return f
    end
    local canvas = FrameStub()
    -- `DrawPath` makes its own child frame of the canvas with the global `CreateFrame`: that one
    -- must be the recording stub, the others stay as they were.
    local createFrame = CreateFrame
    CreateFrame = function(kind, name, parent, ...)
        if parent == canvas then return FrameStub() end
        return createFrame(kind, name, parent, ...)
    end
    local map = WorldMapFrame
    local getCanvas, getMapID = map.GetCanvas, map.GetMapID
    map.GetCanvas = function() return canvas end
    map.GetMapID = function() return 1412 end
    local function Visible()
        local n = 0
        for _, l in ipairs(lines) do
            if l.shown then n = n + 1 end
        end
        return n
    end
    local get, route, current = FG.Get, FG.Guide.Route, FG.Guide.CurrentStep
    local steps = {
        { k = "accept", m = 1412, x = 10, y = 10, t = "a", path = { 50, 60, 55, 64, 60, 66, 62, 70 } },
        { k = "accept", m = 1412, x = 10, y = 10, t = "b" },
    }
    local at = 1
    FG.Get = function(self, key)
        if key == "uiShown" or key == "mapPins" then return true end
        return get(self, key)
    end
    FG.Guide.Route = function() return { steps = steps } end
    FG.Guide.CurrentStep = function() return at end
    local ok, err = pcall(function()
        provider:RefreshAllData()
        assert(Visible() == 3 and created == 3, "a path of 4 points draws 3 lines, got " .. Visible())
        provider:RefreshAllData()
        assert(Visible() == 3 and created == 3, "the lines are reused")
        at = 2
        provider:RefreshAllData()
        assert(Visible() == 0, "no line on a step without a path")
        at = 1
        provider:RefreshAllData()
        assert(Visible() == 3, "the path back")
        provider:RemoveAllData()
        assert(Visible() == 0, "RemoveAllData hides the lines")
    end)
    FG.Get, FG.Guide.Route, FG.Guide.CurrentStep = get, route, current
    map.GetCanvas, map.GetMapID = getCanvas, getMapID
    CreateFrame = createFrame
    assert(ok, err)
end

-- No safety alert while hidden.
local alerts = 0
UIErrorsFrame = { AddMessage = function() alerts = alerts + 1 end }
local health = 10
UnitHealth = function() return health end
UnitHealthMax = function() return 100 end
UnitIsDeadOrGhost = function() return false end
fire("UNIT_HEALTH", "player")
assert(alerts == 0, "no low health alert while hidden")
Press("hide")
assert(pins > 0 and waypoint, "map pins and waypoint back on show")
health = 100
fire("UNIT_HEALTH", "player")
health = 10
fire("UNIT_HEALTH", "player")
assert(alerts == 1, "the low health alert back on show")
WorldMapFrame.IsShown = function() return false end
UIErrorsFrame, UnitHealth, UnitHealthMax, UnitIsDeadOrGhost = nil, nil, nil, nil
StaticPopup_Hide = nil
print("whole addon hide and show ok")

-- WoW Forever's map sets each pin it acquires to let right clicks through, with a function the
-- game blocks from our code in combat: not done then, on the steps' pins and the walk's dots.
do
    local passthrough = 0
    MapCanvasPinMixin = { CheckMouseButtonPassthrough = function() passthrough = passthrough + 1 end }
    InCombatLockdown = function() return true end
    PWStepPinMixin.CheckMouseButtonPassthrough({}, "RightButton")
    PWWalkDotMixin.CheckMouseButtonPassthrough({}, "RightButton")
    assert(passthrough == 0, "not in combat")
    InCombatLockdown = function() return false end
    PWStepPinMixin.CheckMouseButtonPassthrough({}, "RightButton")
    PWWalkDotMixin.CheckMouseButtonPassthrough({}, "RightButton")
    assert(passthrough == 2, "done out of combat")
    MapCanvasPinMixin = nil
    PWStepPinMixin.CheckMouseButtonPassthrough({}, "RightButton")
    assert(passthrough == 2, "Classic Era and TBC: nothing to do")
end

-- The rested reminder on Forever uses the player's XP pool and Boosted Rested together.
do
    local savedXP, savedAuras, savedSecret = GetXPExhaustion, C_UnitAuras, issecretvalue
    local savedMax = UnitXPMax
    local xp, levelXP, debuff = 2540, 80800, nil
    GetXPExhaustion = function() return xp end
    UnitXPMax = function() return levelXP end
    C_UnitAuras = {
        GetPlayerAuraBySpellID = function(id)
            if id == 1229451 then return debuff end
        end,
    }
    local icon = named("PathwrightRestedXP")
    local bar = named("PathwrightToolstrip")
    local setWidth, width = bar.SetWidth, nil
    bar.SetWidth = function(self, w)
        width = w
        setWidth(self, w)
    end
    FG.Toolstrip:Refresh()
    local compactWidth = assert(width)
    local function check(event, lit, unit)
        fire(event, unit)
        assert(icon:IsShown() == lit, "rested XP visibility on " .. event)
    end
    check("PLAYER_ENTERING_WORLD", false)
    xp = 404
    check("UPDATE_EXHAUSTION", false)
    xp = 403
    check("UPDATE_EXHAUSTION", true)
    xp = nil
    check("UPDATE_EXHAUSTION", true)
    assert(width == compactWidth + 20, "a 16px reminder and one gap")
    debuff = { spellId = 1229451 }
    check("UNIT_AURA", true, "party1")
    local combat = InCombatLockdown
    InCombatLockdown = function() return true end
    check("UNIT_AURA", false, "player")
    assert(width > compactWidth and FG.Toolstrip.pending, "hide immediately and defer secure layout")
    InCombatLockdown = combat
    check("PLAYER_REGEN_ENABLED", false)
    assert(width == compactWidth, "the inactive reminder leaves no gap")
    xp = 405
    check("PLAYER_XP_UPDATE", false, "player")
    debuff = nil
    check("UNIT_AURA", false, "player")
    xp = 0
    check("PLAYER_XP_UPDATE", true, "player")
    local secret = {}
    issecretvalue = function(v) return v == secret end
    debuff = secret
    check("UNIT_AURA", false, "player")
    debuff, xp = nil, secret
    check("UPDATE_EXHAUSTION", false)
    xp, levelXP = 1, 0
    check("UPDATE_EXHAUSTION", false)
    UnitXPMax = savedMax
    GetXPExhaustion, C_UnitAuras, issecretvalue = savedXP, savedAuras, savedSecret
    bar.SetWidth = setWidth
    print("rested XP indicator ok")
end

-- XP buffs the guide counts on (WoW Forever): a warning when one is missing, not in combat, not
-- twice within ten minutes, nothing when the game hides the aura.
do
    local told, auras, fighting, hidden = {}, {}, false, {}
    UIErrorsFrame = { AddMessage = function(_, text) table.insert(told, text) end }
    UnitIsDeadOrGhost = function() return false end
    InCombatLockdown = function() return fighting end
    C_UnitAuras = {
        GetPlayerAuraBySpellID = function(id) return hidden[id] or (auras[id] and { spellId = id }) or nil end,
    }
    local route = FG.Guide:Route()
    route.buffs = { "food", "bag" }
    local savedSecret = issecretvalue
    local savedTime = GetTime
    local clock = 5000
    GetTime = function() return clock end
    local savedBagQuest = completed[79976]
    completed[79976] = nil
    fire("PLAYER_REGEN_ENABLED")
    assert(#told == 1 and told[1]:find("food XP"), "only food warns before the bag is earned")
    fire("UNIT_AURA", "player")
    assert(#told == 1, "an unearned bag never warns")
    completed[79976] = true
    fire("PLAYER_REGEN_ENABLED")
    assert(#told == 2 and told[2]:find("Sleeping Bag"), "the earned bag warns immediately")
    fire("UNIT_AURA", "player")
    assert(#told == 2, "not told twice in a row")
    clock = clock + 601
    auras[1243969] = true
    fire("UNIT_AURA", "player")
    assert(#told == 3 and told[3]:find("Sleeping Bag"), "only the bag is missing, told again later")
    clock = clock + 601
    auras[429959] = true
    fire("UNIT_AURA", "player")
    assert(#told == 3, "both active: no warning")
    clock = clock + 601
    auras[429959] = nil
    fighting = true
    fire("UNIT_AURA", "player")
    assert(#told == 3, "no warning in combat")
    fighting = false
    hidden[429959] = { secret = true }
    issecretvalue = function(v) return type(v) == "table" and v.secret == true end
    fire("UNIT_AURA", "player")
    assert(#told == 3, "an aura the game hides is not reported missing")
    issecretvalue, hidden[429959] = savedSecret, nil
    route.buffs = nil
    fire("UNIT_AURA", "player")
    assert(#told == 3, "a guide without buffs never warns")
    completed[79976] = savedBagQuest
    GetTime, C_UnitAuras, UIErrorsFrame, UnitIsDeadOrGhost = savedTime, nil, nil, nil
    InCombatLockdown = function() return false end
    print("buff warnings ok")
end

-- Classic Era (1.15) has no C_QuestLog log functions: the quest log is read through the older
-- globals, and the guide still draws.
local modern = {}
for _, name in ipairs({
    "GetNumQuestLogEntries",
    "GetInfo",
    "GetLogIndexForQuestID",
    "GetTitleForQuestID",
    "IsComplete",
}) do
    modern[name] = C_QuestLog[name]
    C_QuestLog[name] = nil
end
local classicLog = {
    { "Northshire", nil, nil, true, false, nil, nil, 0 },
    { "A Threat Within", 1, nil, false, false, 1, nil, 783 },
    { "Wolves Across the Border", 2, nil, false, false, nil, nil, 33 },
    { "Lost Necklace", 3, nil, false, false, -1, nil, 85 },
}
GetNumQuestLogEntries = function() return #classicLog, 3 end
GetQuestLogTitle = function(i) return unpack(classicLog[i] or {}) end
GetQuestLogIndexByID = function(q)
    for i, e in ipairs(classicLog) do
        if e[8] == q then return i end
    end
    return 0
end
local log = FG.QuestLog
assert(log.GetNumQuestLogEntries() == 4, "entries")
assert(log.GetInfo(1).isHeader and log.GetInfo(2).questID == 783, "headers and quests")
assert(log.GetLogIndexForQuestID(33) == 3 and log.GetLogIndexForQuestID(99) == nil, "log index")
assert(log.GetTitleForQuestID(33) == "Wolves Across the Border", "title")
assert(log.IsComplete(783) and not log.IsComplete(33) and log.IsFailed(85), "complete and failed")
FG.Guide:Refresh()
FG.Tracker:Refresh()
for name, fn in pairs(modern) do
    C_QuestLog[name] = fn
end
print("classic era quest log ok")

-- Collector: rows as the contribution format expects them, on Forever and Classic payloads.
-- Rows are strings (seq|time|event|quest|entityType|entityID|map|x|y|level|data): decoded here
-- into the tables they replace, as the app reads them (keys typed as in its schemas).
local BOOL_KEYS = { complete = true, trivial = true, repeatable = true, elite = true, pet = true, died = true }
local PAIR_KEYS = { items = true, nodes = true }
local TEXT_KEYS = { title = true, name = true, mode = true }
local function decodeRow(row)
    if type(row) ~= "string" then return row end
    local f = {}
    for field in (row .. "|"):gmatch("([^|]*)|") do
        f[#f + 1] = field
    end
    assert(#f == 11, "11 fields: " .. row)
    local function num(v) return v ~= "" and assert(tonumber(v), row) or false end
    local data = false
    if f[11] ~= "" then
        data = {}
        for pair in f[11]:gmatch("[^;]+") do
            local k, v = pair:match("^([^=]+)=(.*)$")
            assert(k and data[k] == nil, "data pair: " .. pair)
            if BOOL_KEYS[k] then
                assert(v == "1", "booleans written as 1: " .. pair)
                data[k] = true
            elseif PAIR_KEYS[k] then
                data[k] = {}
                for a, b in v:gmatch("(%d+):(%d+)") do
                    table.insert(data[k], { tonumber(a), tonumber(b) })
                end
            elseif TEXT_KEYS[k] then
                data[k] = v:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
            else
                data[k] = assert(tonumber(v), "number: " .. pair)
            end
        end
    end
    local entityType = f[5] ~= "" and f[5] or false
    return {
        num(f[1]),
        num(f[2]),
        f[3],
        num(f[4]),
        entityType,
        num(f[6]),
        num(f[7]),
        num(f[8]),
        num(f[9]),
        num(f[10]),
        data,
    }
end
local function lastRow(event)
    for i = #char.events, 1, -1 do
        local row = decodeRow(char.events[i])
        if row[3] == event then return row, i end
    end
end
local function rowsSince(event, from)
    local out = {}
    for i = from + 1, #char.events do
        local row = decodeRow(char.events[i])
        if row[3] == event then table.insert(out, row) end
    end
    return out
end
local accepted = lastRow("accept")
assert(accepted and accepted[4] == 179, "Forever accept: (questID)")

-- Classic Era and TBC: QUEST_ACCEPTED gives (questLogIndex, questID), the log has no C_QuestLog.
for name in pairs(modern) do
    C_QuestLog[name] = nil
end
fire("QUEST_ACCEPTED", 3, 33)
accepted = lastRow("accept")
assert(accepted[4] == 33, "Classic accept: quest ID, not the log index: " .. tostring(accepted[4]))
assert(accepted[11].title == "Wolves Across the Border" and accepted[11].level == 2, "Classic accept title")

-- Quest greeting: Classic Era and TBC have no GetActiveQuestID, the title is found in the log.
local greetingActive = { "Wolves Across the Border", "Not In The Log" }
GetNumActiveQuests = function() return #greetingActive end
GetActiveTitle = function(i) return greetingActive[i], false end
GetActiveQuestID = nil
greeting = {}
fire("QUEST_GREETING")
local active = lastRow("active")
assert(active and active[4] == 33 and active[5] == "npc" and active[6] == 658, "Classic greeting active quest")
GetActiveQuestID = function(i) return i == 1 and 783 or 0 end
fire("QUEST_GREETING")
assert(lastRow("active")[4] == 783, "Forever greeting active quest")
GetNumActiveQuests = function() return 0 end

-- Classic Era: the completed quests come from GetQuestsCompleted.
local allCompleted = C_QuestLog.GetAllCompletedQuestIDs
C_QuestLog.GetAllCompletedQuestIDs = nil
GetQuestsCompleted = function() return { [33] = true, [12] = true } end
fire("PLAYER_LOGOUT")
do
    local done = PathwrightDB.profiles["Brouz-Realm"].completed
    assert(done[1] == 12 and done[2] == 33 and #done == 2, "Classic completed quests")
end
assert(char.completed == nil and char.questLog == nil, "not copied into the collector's table")
C_QuestLog.GetAllCompletedQuestIDs = allCompleted
for name, fn in pairs(modern) do
    C_QuestLog[name] = fn
end
print("collector quests ok")

-- Turn-ins are not recorded as removed, in either order; an abandon is.
runTimers() -- those queued so far (tracker, party, talents...)
local mark = #char.events
fire("QUEST_TURNED_IN", 4001, 100, 0)
fire("QUEST_REMOVED", 4001)
fire("QUEST_REMOVED", 4002) -- Classic: removed before turned in
fire("QUEST_TURNED_IN", 4002, 100, 0)
fire("QUEST_REMOVED", 4003)
runTimers()
local removed = rowsSince("removed", mark)
assert(#removed == 1 and removed[1][4] == 4003 and removed[1][11] == false, "only the abandon is removed")
print("collector removed ok")

-- Loot: read before fast loot takes the slots, one row per corpse with item quantities (AoE
-- loot), money skipped, a window read once.
local slots = {
    { link = nil, sources = { "Creature-0-1-2-3-299-00A", 1 } }, -- money
    { link = "|Hitem:750::|h", sources = { "Creature-0-1-2-3-299-00A", 1, "Creature-0-1-2-3-300-00B", 2 } },
    { link = "|Hitem:2589::|h", sources = { "Creature-0-1-2-3-299-00A", 3 } },
}
GetNumLootItems = function() return #slots end
GetLootSlotLink = function(i) return slots[i] and slots[i].link end
GetLootSourceInfo = function(i) return unpack(slots[i] and slots[i].sources or {}) end
LootSlot = function(i) slots[i] = nil end
local clock = GetTime
GetTime = function() return clock() + 5000 end
mark = #char.events
fire("LOOT_READY", false)
assert(not slots[1] and not slots[2] and not slots[3], "fast loot took the slots")
local loot = rowsSince("loot", mark)
assert(#loot == 2, "one loot row per corpse, got " .. #loot)
local a, b = loot[1][11].items, loot[2][11].items
assert(
    loot[1][6] == 299 and #a == 2 and a[1][1] == 750 and a[1][2] == 1 and a[2][1] == 2589 and a[2][2] == 3,
    "corpse A"
)
assert(loot[2][6] == 300 and #b == 1 and b[1][1] == 750 and b[1][2] == 2, "corpse B: its own quantity")
fire("LOOT_READY", false)
fire("LOOT_OPENED", false)
assert(#rowsSince("loot", mark) == 2, "a loot window recorded once")
GetTime = clock
print("collector loot ok")

-- Flight master: node IDs and states only, bounded; Classic: the continent's map.
mark = #char.events
fire("TAXIMAP_OPENED")
local taxi = rowsSince("taxi", mark)[1][11]
assert(taxi.map == 1415 and taxi.nodes[1][1] == 6 and taxi.nodes[1][2] == 0 and taxi.nodes[3][2] == 2, "taxi nodes")
local manyNodes = {}
for i = 1, 200 do
    manyNodes[i] = { nodeID = i, name = "A long flight master name " .. i, slotIndex = i }
end
C_TaxiMap.GetAllTaxiNodes = function() return manyNodes end
TaxiNodeGetType = function(slot) return slot == 1 and "CURRENT" or slot == 2 and "REACHABLE" or "DISTANT" end
GetTaxiMapID = nil
fire("TAXIMAP_OPENED")
taxi = lastRow("taxi")[11]
assert(taxi.map == 1415, "Classic: continent map " .. tostring(taxi.map))
assert(#taxi.nodes == 128 and #taxi.nodes[1] == 2, "nodes bounded, ids and states only")
assert(taxi.nodes[1][2] == 0 and taxi.nodes[2][2] == 1 and taxi.nodes[3][2] == 2, "Classic node states")
print("collector taxi ok")

-- Transit: a boat ride is timed from the docked boat, a hearthstone is told apart.
local now, speed, here = 10000, 7, { 1437, 0.10, 0.10 }
local clockTime = time
time = function() return now end
GetUnitSpeed = function() return speed end
local continents = { [1415] = true, [1414] = true }
C_Map.GetMapInfo = function(m)
    if continents[m] then return { mapID = m, mapType = 2, parentMapID = 947 } end
    return { mapID = m, mapType = 3, parentMapID = m < 1415 and 1414 or 1415 }
end
C_Map.GetBestMapForUnit = function() return here[1] end
C_Map.GetPlayerMapPosition = function()
    return {
        GetXY = function() return here[2], here[3] end,
    }
end
local function sample(t, map, x, y, v)
    now, here, speed = t, { map, x, y }, v
    fire("ZONE_CHANGED_NEW_AREA")
end
mark = #char.events
sample(10000, 1437, 0.10, 0.10, 7) -- walking on the dock
sample(10005, 1437, 0.105, 0.10, 0) -- on the boat
sample(10010, 1437, 0.105, 0.10, 0) -- waiting on board
sample(10015, 1437, 0.12, 0.10, 0) -- the boat leaves
sample(10020, 1437, 0.14, 0.10, 0)
sample(10090, 1411, 0.50, 0.50, 0) -- landed on the other continent
local transit = rowsSince("transit", mark)
assert(#transit == 1, "one transit")
local ride = transit[1][11]
assert(ride.mode == "ride" and ride.seconds == 80 and ride.fromMap == 1437 and ride.fromX == 10.5, "boat ride")
sample(10100, 1411, 0.50, 0.50, 0)
fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 8690)
sample(10130, 1426, 0.30, 0.70, 0)
local hearth = lastRow("transit")[11]
assert(hearth.mode == "hearth" and hearth.seconds == 30 and hearth.fromMap == 1411, "hearthstone")
sample(10200, 1426, 0.30, 0.71, 7) -- walking into a portal
sample(10203, 1411, 0.40, 0.40, 0)
local portal = lastRow("transit")[11]
assert(portal.mode == nil and portal.seconds == 3 and portal.fromY == 71, "walked in: no mode")
time = clockTime
print("collector transit ok")

-- Phase 2 recordings: fights, objective progress, guide steps, flights, spawn ages; Forever
-- secret values degrade to the fallbacks without errors.
local clockNow = 50000
local realGetTime = GetTime
GetTime = function() return clockNow end
GetServerTime = function() return 1000000 end
local function spawnGUID(npc, age) return string.format("Creature-0-1-2-3-%d-%010X", npc, (1000000 - age) % 8388608) end
local guids, levels, classes, exists = {}, {}, {}, {}
local unitGUID, unitLevel = UnitGUID, UnitLevel
UnitGUID = function(u)
    if guids[u] ~= nil then return guids[u] or nil end
    return unitGUID(u)
end
UnitLevel = function(u)
    if u == "player" then return playerLevel end
    return levels[u] or 1
end
UnitExists = function(u) return exists[u] or false end
UnitClassification = function(u) return classes[u] or "normal" end
UnitIsDead = function() return false end
UnitCanAttack = function() return true end
UnitName = function(u) return u == "player" and "Brouz" or "Kobold Vermin" end
UnitReaction = function() return 2 end
local secret = {}
issecretvalue = function(v) return v ~= nil and secret[v] == true end
local xpNow, xpMax = 100, 400
UnitXP = function() return xpNow end
UnitXPMax = function() return xpMax end
COMBATLOG_XPGAIN_FIRSTPERSON = "%s dies, you gain %d experience."
COMBATLOG_XPGAIN_EXHAUSTION1 = "%s dies, you gain %d experience. (%s exp %s bonus)"
playerLevel = 5

-- Target read out of combat: a seen row with its spawn age and elite.
local koboldGUID = spawnGUID(299, 90)
guids.target, levels.target, classes.target, exists.target = koboldGUID, 5, "elite", true
here = { 1426, 0.30, 0.70 }
mark = #char.events
fire("PLAYER_TARGET_CHANGED")
local seenRow = rowsSince("seen", mark)[1]
assert(seenRow and seenRow[6] == 299 and seenRow[11].age == 90 and seenRow[11].elite == true, "seen: age and elite")
assert(seenRow[11].name == "Kobold Vermin" and seenRow[11].level == 5, "seen: name and level")
-- The same NPC close by: one row per 5% of the map; elsewhere, a row without the name again.
guids.mouseover, exists.mouseover = spawnGUID(299, 30), true
here = { 1426, 0.301, 0.701 }
fire("UPDATE_MOUSEOVER_UNIT")
fire("UPDATE_MOUSEOVER_UNIT")
here = { 1426, 0.50, 0.50 }
fire("UPDATE_MOUSEOVER_UNIT")
local seenRows = rowsSince("seen", mark)
assert(#seenRows == 2 and seenRows[2][11].name == nil and seenRows[2][11].age == 30, "seen deduped, name once")
-- A secret GUID (Forever, restricted): nothing recorded, no error.
local hiddenGUID = spawnGUID(300, 5)
secret[hiddenGUID] = true
guids.mouseover = hiddenGUID
here = { 1426, 0.70, 0.70 }
fire("UPDATE_MOUSEOVER_UNIT")
assert(#rowsSince("seen", mark) == 2, "secret GUID: no seen row")
-- A static NPC up since the realm restart: seen without its age.
guids.mouseover = spawnGUID(302, 7200)
here = { 1426, 0.90, 0.90 }
fire("UPDATE_MOUSEOVER_UNIT")
local static = rowsSince("seen", mark)[3]
assert(static and static[6] == 302 and static[11].age == nil, "no age past an hour")
-- Safety alerts on a target whose level is secret (a table here: comparing it errors, as a
-- secret does): not compared, no error (checked below).
local secretLevel = {}
secret[secretLevel] = true
guids.target, levels.target = spawnGUID(301, 5), secretLevel
fire("PLAYER_TARGET_CHANGED")
guids.target, levels.target = koboldGUID, 5
fire("PLAYER_TARGET_CHANGED")
-- Low health alert while the health is secret (WoW Forever in combat; a table here: arithmetic
-- on it errors, as on a secret): not read, no error (checked below).
do
    local secretHealth = {}
    secret[secretHealth] = true
    UnitHealth, UnitHealthMax = function() return secretHealth end, function() return 100 end
    UnitIsDeadOrGhost = function() return false end
    fire("UNIT_HEALTH", "player")
    UnitHealth, UnitHealthMax, UnitIsDeadOrGhost = nil, nil, nil
end

-- Fight 1: the target turns secret when the fight begins (the GUID read before is used), the
-- kill is told by the XP message only (secret attacker on PARTY_KILL).
guids.pet, exists.pet = "Pet-0-1-2-3-416-0000000001", true
here = { 1426, 0.40, 0.40 }
secret[koboldGUID] = true
mark = #char.events
fire("PLAYER_REGEN_DISABLED")
secret["Player-1-2"] = true
fire("PARTY_KILL", "Player-1-2", koboldGUID)
secret["Player-1-2"] = nil
fire("CHAT_MSG_COMBAT_XP_GAIN", "Kobold Vermin dies, you gain 45 experience. (45 exp Rested bonus)")
fire("CHAT_MSG_COMBAT_XP_GAIN", "You gain 120 experience.") -- not a kill
fire("PLAYER_TARGET_DIED")
xpNow, clockNow = 145, clockNow + 12
fire("PLAYER_REGEN_ENABLED")
local fight = rowsSince("combat", mark)[1]
assert(fight and fight[5] == "npc" and fight[6] == 299, "fight against the target read before")
assert(fight[7] == 1426 and fight[8] == 40 and fight[9] == 40, "where the fight began")
local f = fight[11]
assert(f.seconds == 12 and f.kills == 1 and f.xp == 45 and f.mobLevel == 5, "fight 1: " .. tostring(f.kills))
assert(f.elite == true and f.pet == true and f.died == nil, "fight 1 flags")
secret[koboldGUID] = nil

-- Fight 2: PARTY_KILL readable (player then pet), counted once each despite the XP messages;
-- XP across a level up.
local wolf1, wolf2 = spawnGUID(525, 600), spawnGUID(525, 50000) -- wolf2: up since the restart
guids.target, levels.target, classes.target = wolf1, 6, "normal"
xpNow, xpMax = 380, 400
mark = #char.events
fire("PLAYER_REGEN_DISABLED")
fire("PARTY_KILL", "Player-1-2", wolf1)
fire("CHAT_MSG_COMBAT_XP_GAIN", "Mangy Wolf dies, you gain 50 experience.")
here = { 1426, 0.42, 0.40 } -- kill rows: one per NPC and spot
fire("PARTY_KILL", "Pet-0-1-2-3-416-0000000001", wolf2)
fire("PARTY_KILL", "Player-9-9", spawnGUID(525, 800)) -- someone else's
playerLevel, xpNow, clockNow = 6, 30, clockNow + 20
fire("PLAYER_REGEN_ENABLED")
f = rowsSince("combat", mark)[1][11]
assert(f.kills == 2 and f.xp == 50 and f.mobLevel == 6 and f.elite == nil, "fight 2: kills " .. tostring(f.kills))
local kills = rowsSince("kill", mark)
assert(#kills == 2 and kills[1][11].age == 600, "kill rows with spawn age")
assert(kills[2][11] == false, "no age past an hour (it would tell the time of day)")

-- Fight 3: nothing killed, short: no row. Fight 4: target died, the player too.
exists.target, exists.pet = false, false
mark = #char.events
fire("PLAYER_REGEN_DISABLED")
clockNow = clockNow + 1
fire("PLAYER_REGEN_ENABLED")
assert(#rowsSince("combat", mark) == 0, "short fight without kill skipped")
fire("PLAYER_REGEN_DISABLED")
fire("PLAYER_TARGET_DIED")
fire("PLAYER_DEAD")
clockNow = clockNow + 8
fire("PLAYER_REGEN_ENABLED")
f = rowsSince("combat", mark)[1]
assert(f[6] == false and f[11].kills == 1 and f[11].died == true and f[11].pet == nil, "fight 4")
-- In an instance: nothing.
IsInInstance = function() return true end
mark = #char.events
fire("PLAYER_REGEN_DISABLED")
fire("PLAYER_TARGET_DIED")
clockNow = clockNow + 10
fire("PLAYER_REGEN_ENABLED")
IsInInstance = function() return false end
assert(#rowsSince("combat", mark) == 0, "no fight recorded in instances")
print("collector combat ok")

-- Objective progress: a row when a count goes up, the log read once per burst of events.
local objectives = { [179] = { { numFulfilled = 2, numRequired = 8 } } }
local questLog = { 179 }
C_QuestLog.GetNumQuestLogEntries = function() return #questLog end
C_QuestLog.GetInfo = function(i) return { questID = questLog[i], title = "Q" .. questLog[i], level = 2 } end
C_QuestLog.GetQuestObjectives = function(q) return objectives[q] end
fire("QUEST_LOG_UPDATE")
runTimers()
mark = #char.events
objectives[179][1].numFulfilled = 4
objectives[180] = { { numFulfilled = 5, numRequired = 8 } }
questLog[2] = 180 -- accepted with some done already: not progress
fire("QUEST_LOG_UPDATE")
fire("QUEST_WATCH_UPDATE")
fire("UNIT_QUEST_LOG_CHANGED", "player")
local queued = #timers
runTimers()
local progress = rowsSince("progress", mark)
assert(#progress == 1 and progress[1][4] == 179, "one progress row, got " .. #progress)
assert(progress[1][11].index == 1 and progress[1][11].value == 4, "objective 1 at 4")
objectives[180][1].numFulfilled = 6
fire("UNIT_QUEST_LOG_CHANGED", "target")
runTimers()
assert(#rowsSince("progress", mark) == 1, "another unit's quest log: not read")
fire("QUEST_LOG_UPDATE")
assert(queued > 0 and #rowsSince("progress", mark) == 1, "read a moment later")
runTimers()
assert(#rowsSince("progress", mark) == 2, "the new quest's progress")
print("collector progress ok")

-- Guide steps: done while playing recorded with their index, not those marked by hand.
FG.Routes["step-test"] = {
    race = 7,
    class = 8,
    faction = "Alliance",
    fromLevel = 1,
    toLevel = 60,
    time = 1,
    steps = {
        { k = "accept", t = "Accept One", q = 9101, lvl = 6 },
        { k = "objective", t = "Boar Meat x4", q = 9101, o = 1, n = "Boar Meat", lvl = 6, d = 240 },
        { k = "train", t = "Train", lvl = 6 },
        { k = "grind", t = "Grind", lvl = 60 },
    },
}
objectives[9101] = { { text = "Boar Meat: 2/4", numFulfilled = 2, numRequired = 4, finished = false } }
useRoute("step-test")
mark = #char.events
onQuest[9101] = true
FG.Guide:Advance()
assert(char.guide.step == 2 and #rowsSince("step", mark) == 0, "an accept has its own row")
objectives[9101][1].finished = true
FG.Guide:Advance()
local steps = rowsSince("step", mark)
assert(#steps == 1 and steps[1][4] == 9101, "step done while playing")
assert(steps[1][11].step == 2 and steps[1][11].planned == 240, "its index and planned time")
Press("skip")
FG.Guide:Advance()
assert(char.guide.step == 4 and #rowsSince("step", mark) == 1, "a step marked by hand is not recorded")
onQuest[9101] = nil
print("collector steps ok")

-- Flights: from the flight master to the landing.
local onTaxi = false
UnitOnTaxi = function() return onTaxi end
here = { 1426, 0.30, 0.70 }
mark = #char.events
fire("PLAYER_CONTROL_LOST")
onTaxi = true
runTimers()
clockNow = clockNow + 125
onTaxi = false
here = { 1453, 0.60, 0.40 }
fire("PLAYER_CONTROL_GAINED")
local flightRow = rowsSince("flight", mark)[1]
assert(flightRow and flightRow[7] == 1453 and flightRow[8] == 60, "landing position")
assert(flightRow[11].fromMap == 1426 and flightRow[11].fromX == 30 and flightRow[11].seconds == 125, "flight")
fire("PLAYER_CONTROL_LOST") -- stunned, not a flight
runTimers()
fire("PLAYER_CONTROL_GAINED")
assert(#rowsSince("flight", mark) == 1, "control lost without a flight")
print("collector flight ok")

-- Quest details carry the XP reward when the client gives it.
GetRewardXP = function() return 450 end
GetQuestID = function() return 9201 end
fire("QUEST_DETAIL", 0)
GetQuestID = questID
assert(lastRow("detail")[4] == 9201 and lastRow("detail")[11].xp == 450, "detail XP")
print("collector detail ok")

-- Rows are strings; game text is percent-encoded where it would break the format.
C_QuestLog.GetLogIndexForQuestID = function() return 1 end
C_QuestLog.GetInfo = function() return { questID = 9301, title = "A|B;C=D%E\nF", level = 7 } end
fire("QUEST_ACCEPTED", 9301)
local raw = char.events[#char.events]
assert(type(raw) == "string" and raw:find("|accept|9301|", 1, true), "a string row: " .. tostring(raw))
assert(raw:find("level=7;title=A%7CB%3BC%3DD%25E%0AF", 1, true), "text encoded: " .. raw)
assert(lastRow("accept")[11].title == "A|B;C=D%E\nF", "and read back")
print("collector rows ok")

GetTime = realGetTime
issecretvalue = function() return false end

-- Handler errors are counted in the saved variables, a few short messages.
for msg in pairs(PathwrightDB.errors or {}) do
    error("handler error: " .. msg)
end
FG:On("FG_TEST", function() error("boom") end)
fire("FG_TEST")
fire("FG_TEST")
local errorKey, errorCount = pairs(PathwrightDB.errors)(PathwrightDB.errors)
assert(errorKey:find("FG_TEST", 1, true) and errorKey:find("boom", 1, true) and errorCount == 2, "error counted")
for i = 1, 30 do
    FG:Error("test", i .. string.rep("x", 300))
end
local kept = 0
for msg in pairs(PathwrightDB.errors) do
    kept = kept + 1
    assert(#msg <= 200, "message shortened")
end
assert(kept == 20, "errors capped, got " .. kept)
print("error counter ok")

-- Rows the app has (Sent.lua) are dropped at login, the seq keeps growing; at most 20000 rows.
PathwrightSent = { ["Brouz-Realm"] = decodeRow(char.events[3])[1] }
local before = #char.events
FG.Collector:Purge()
assert(#char.events == before - 3 and decodeRow(char.events[1])[1] > PathwrightSent["Brouz-Realm"], "sent rows dropped")
local output
local realPrint = print
print = function(s) output = s end
Press("status")
print = realPrint
assert(output:find(#char.events .. " not sent yet", 1, true), "status: " .. output)
for i = 1, 20010 do
    char.events[#char.events + 1] = { char.seq + i, 0, "kill", false, "npc", 6, false, false, false, 1, false }
end
char.seq = char.seq + 20010
PathwrightSent = { ["Brouz-Realm"] = char.seq + 50 } -- saved variables older than what the app has
FG.Collector:Purge()
assert(#char.events == 0 and char.seq == PathwrightSent["Brouz-Realm"], "all sent, the seq follows")
PathwrightSent = nil
PathwrightDB.errors = nil -- full after the error counter test
for i = 1, 20010 do
    char.events[i] = { char.seq + i, 0, "kill", false, "npc", 6, false, false, false, 1, false }
end
char.seq = char.seq + 20010
FG.Collector:Purge()
assert(#char.events == 20000 and char.events[20000][1] == char.seq, "capped, the newest kept")
local capLogged = false
for msg in pairs(PathwrightDB.errors) do
    if msg:find("oldest dropped", 1, true) then capLogged = true end
end
assert(capLogged, "the cap is logged")
print("collector purge ok")

-- In a function of their own: the main chunk is out of locals.
local function ExportImport()
    -- JSON for the profile export: exact text for the usual values, numbers read back the same.
    assert(
        FG.JSON({ b = { 1, 2, 3 }, a = 1, c = {}, d = 'q"\\\n\1', e = 0.1, g = true, h = -3, i = { [2] = "x" } })
            == [[{"a":1,"b":[1,2,3],"c":[],"d":"q\"\\\u000a\u0001","e":0.1,"g":true,"h":-3,"i":{"2":"x"}}]],
        "json: "
            .. FG.JSON({ b = { 1, 2, 3 }, a = 1, c = {}, d = 'q"\\\n\1', e = 0.1, g = true, h = -3, i = { [2] = "x" } })
    )
    for _, v in ipairs({ 1 / 3, 29.93, -1e-7, 1e300, 2 ^ 53 + 2, 1712345678 }) do
        assert(tonumber(FG.JSON(v)) == v, "json number " .. FG.JSON(v))
    end
    assert(FG.JSON(1712345678) == "1712345678" and FG.JSON(0 / 0) == "null", "json integers, NaN")

    --- Whether `text` parses as JSON, and passes the Python `check` (assertions on `d`); nil when
    --- python3 is not there.
    local function PythonJson(text, check)
        if os.execute("python3 -c '' 2>/dev/null") ~= 0 and os.execute("python3 -c '' 2>/dev/null") ~= true then
            return nil
        end
        local path = os.tmpname()
        local f = assert(io.open(path, "wb"))
        f:write(text)
        f:close()
        local script = "import json,sys; d = json.load(open(sys.argv[1], encoding='utf-8')); " .. (check or "")
        local status = os.execute("python3 -I -c " .. string.format("%q", script):gsub("%$", "\\$") .. " " .. path)
        os.remove(path)
        return status == 0 or status == true
    end

    local deflate = LibStub("LibDeflate")

    -- "Export my character": a fresh profile, compressed, in a window to copy (no collector rows).
    local profile = PathwrightDB.profiles["Brouz-Realm"]
    char.events = { "101|5|kill||npc|6|1426|30|70|1|", "102|6|kill||npc|6|1426|30|70|1|", { 103, 0, "kill" } }
    char.events[4] = '104|7|loot||npc|6|1426|30|70|1|name=Wolf "Meat"%0A'
    PathwrightDB.sent = { ["Brouz-Realm"] = 101 }
    profile.flights = { [12] = true, [2] = true, [7] = false }
    playerLevel = 4
    Press("export")
    local window, edit, action, status = FG.TextWindow:Parts()
    assert(window:IsShown() and not action:IsShown(), "export window shown, no second button")
    local exported = edit:GetText()
    -- `FG_PROFILE_EXPORT=<file> luajit addon/tests/smoke.lua`: this export also written into <file>
    -- (the web app's fixtures of the released addons' exports, crates/fg-web/tests/profiles), and
    -- with `FG_SAVED_VARIABLES=<file>` the saved variables as they are now (the desktop app's,
    -- crates/fg-contrib/tests/saved-variables).
    local function Fixture(variable, text)
        if not os.getenv(variable) then return end
        local file = assert(io.open(os.getenv(variable), "wb"))
        file:write(text, "\n")
        file:close()
    end
    Fixture("FG_PROFILE_EXPORT", exported)
    Fixture("FG_SAVED_VARIABLES", "PathwrightDB = " .. assert(FG.Import.Serialize(PathwrightDB)):gsub("^return ", ""))
    assert(exported:sub(1, 5) == "FGP1:" and exported:match("^FGP1:[%w%(%)]+$"), "export prefix and alphabet")
    local json = deflate:DecompressDeflate(deflate:DecodeForPrint(exported:sub(6)))
    assert(json == FG.Export:Json(), "export round trip")
    assert(json:find('"flights":[2,12]', 1, true), "flights as a sorted list")
    assert(not json:find('"collector"', 1, true) and not json:find("|kill|", 1, true), "no collector rows")
    assert(json:find('"level":4', 1, true), "a fresh snapshot")
    local parsed = PythonJson(
        json,
        "assert d['format'] == 'factoruide-profile' and d['version'] == 1 and d['edition'] == 'forever'; "
            .. "assert d['addon'] == '0.13.0' and d['character'] == 'Brouz-Realm'; "
            .. "assert d['profile']['flights'] == [2, 12] and d['profile']['class'] == 'MAGE'; "
            .. "assert sorted(d) == ['addon', 'character', 'edition', 'format', 'profile', 'version']"
    )
    assert(parsed ~= false, "export JSON read by Python")
    print("profile export ok" .. (parsed == nil and " (python3 missing: JSON not parsed)" or ""))

    -- "Import a guide…": guides pasted from the apps, one text each (or several in one); imports add up.
    local fixture = assert(io.open("addon/tests/fixtures/Routes.lua")):read("*a")
    -- Without the older apps' assignments.
    local plain = fixture:gsub("%-%- Which guide each character follows.-}\n", "")
    assert(not plain:find("Assignments", 1, true), "fixture without assignments")
    --- A guide's text as the apps export it: `name`, computed at `created`, for class `class`.
    local function GuideLua(name, created, class, extra)
        local lua = plain:gsub("gnome%-mage", name)
        if class then lua = lua:gsub("class = 8,", "class = " .. class .. ",", 1) end
        return lua
            .. string.format("FG.Routes[%q].created = %d\nFG.Routes[%q].version = 3\n", name, created, name)
            .. (extra or "")
    end
    local function Empty(t) return t == nil or pairs(t)(t) == nil end
    local function Encode(lua) return "FGG1:" .. deflate:EncodeForPrint(deflate:CompressDeflate(lua)) end
    local guideLua = GuideLua(
        "web-mage",
        1000,
        nil,
        'FG.Config = { locale = "enUS", compassShown = false }\n'
            .. 'PathwrightSent = { ["Brouz-Realm"] = 150, ["Other-Realm"] = 3 }\n'
    )
    local guideString = Encode(guideLua)
    Press("import")
    assert(window:IsShown() and action:IsShown() and (edit:GetText() or "") == "", "import window, empty box")
    local function Click(text)
        FG.Import:Open()
        edit:SetText(text)
        action.OnClick()
        return status:GetText()
    end
    reloaded = false
    assert(Click("hello"):find("FGG1:", 1, true), "bad prefix refused")
    assert(Click("FGG1:abc!!$"):find("abîmé", 1, true), "corrupt text refused: " .. status:GetText())
    assert(Click(guideString:sub(1, 200)):find("abîmé", 1, true), "cut text refused")
    local notLua = "FGG1:" .. deflate:EncodeForPrint(deflate:CompressDeflate("FG.Routes = {"))
    assert(Click(notLua):find("pas pu être lu", 1, true), "Lua errors refused")
    -- Made by a newer app for a newer addon (its format above the addon's): refused, the player
    -- told to update the addon. Today's format and none (older apps) are read (ReleasedGuides).
    local newer = GuideLua("web-next", 1000)
        .. string.format('FG.Routes["web-next"].format = %d\n', FG.Import.FORMAT + 1)
    assert(Click(Encode(newer)):find("mettez à jour l'addon", 1, true), "newer format refused: " .. status:GetText())
    assert(not reloaded and Empty(PathwrightDB.guides), "nothing kept from bad strings")
    -- Pasted: the game sends the characters one by one in the same frame (OnChar), the box
    -- itself holds little; the next frame joins them. Spaces and line breaks picked up with the
    -- copy do not matter.
    local pasteTime = GetTime
    GetTime = function() return 42 end
    local text = guideString:sub(1, 100) .. "\n  " .. guideString:sub(101)
    edit:SetText("")
    for i = 1, #text do
        edit.OnChar(edit, text:sub(i, i))
    end
    GetTime = pasteTime
    assert(rawget(edit, "OnUpdate"), "the paste is joined on the next frame")
    edit.OnUpdate(edit)
    assert(not rawget(edit, "OnUpdate"), "joined once")
    assert(edit:GetText():sub(1, 5) == "FGG1:" and #edit:GetText() < 80, "the box shows the paste's beginning only")
    assert(status:GetText():find("Ko", 1, true), "the paste's size told: " .. status:GetText())
    action.OnClick()
    local kept = PathwrightDB.guides["web-mage"]
    assert(reloaded and kept and kept.created == 1000 and kept.version == 3, "guide kept, interface reloaded")
    assert(PathwrightDB.sent["Brouz-Realm"] == 150 and PathwrightDB.sent["Other-Realm"] == 3, "sent seq imported")
    assert(#FG.Collector:Pending().events == 0, "rows up to the imported seq are sent")
    FG.Import:ApplySaved()
    assert(FG.Routes["web-mage"] and FG.Routes["gnome-mage"], "imported guides beside the files'")
    assert(FG.Routes["web-mage"].created == 1000 and #FG.Routes["web-mage"].steps > 10, "the guide read back")
    assert(FG.Import.info["web-mage"].source == "import" and FG.Import.info["gnome-mage"].source == "app", "sources")
    assert(
        FG.Config.locale ~= "enUS" and FG:Get("compassShown") == true and FG.Lang() == "frFR",
        "imported Config ignored"
    )
    useRoute("web-mage")
    assert(FG.Guide:Route() == FG.Routes["web-mage"] and char.guide.route == "web-mage", "imported guide followed")

    -- A second text adds its guide to the first one.
    reloaded = false
    Click(Encode(GuideLua("web-warrior", 1100, 1)))
    assert(reloaded and PathwrightDB.guides["web-mage"] and PathwrightDB.guides["web-warrior"], "imports add up")
    -- The same guide computed later: replaces it, no question; computed at the same time: too.
    calls.StaticPopup_Show = nil
    Click(Encode(GuideLua("web-mage", 1200)))
    assert(PathwrightDB.guides["web-mage"].created == 1200 and not calls.StaticPopup_Show, "newer replaces")
    Click(Encode(GuideLua("web-mage", 1200)))
    assert(PathwrightDB.guides["web-mage"].created == 1200 and not calls.StaticPopup_Show, "same: replaced quietly")
    -- Computed before the one kept: asked; "no" keeps it, "yes" replaces it. The other guides of
    -- the text are kept either way.
    reloaded = false
    Click(Encode(GuideLua("web-mage", 900) .. GuideLua("web-rogue", 1300, 4)))
    local popup = calls.StaticPopup_Show
    assert(popup and popup[1] == "PATHWRIGHT_OLDER_GUIDE", "asked")
    assert(popup[2]:find("web-mage", 1, true) and popup[2]:find("1970-01-01", 1, true), "question: " .. popup[2])
    assert(not reloaded and PathwrightDB.guides["web-mage"].created == 1200, "nothing kept before the answer")
    StaticPopupDialogs.PATHWRIGHT_OLDER_GUIDE.OnCancel()
    assert(PathwrightDB.guides["web-mage"].created == 1200, "no: kept")
    assert(PathwrightDB.guides["web-rogue"] and reloaded, "the newer guide of the text kept anyway")
    reloaded = false
    calls.StaticPopup_Show = nil
    Click(Encode(GuideLua("web-mage", 900)))
    assert(calls.StaticPopup_Show, "asked again")
    StaticPopupDialogs.PATHWRIGHT_OLDER_GUIDE.OnAccept()
    assert(PathwrightDB.guides["web-mage"].created == 900 and reloaded, "yes: replaced")
    -- Answered "no" with nothing else in the text: nothing to reload.
    reloaded = false
    Click(Encode(GuideLua("web-mage", 800)))
    StaticPopupDialogs.PATHWRIGHT_OLDER_GUIDE.OnCancel()
    assert(PathwrightDB.guides["web-mage"].created == 900 and not reloaded, "nothing imported")

    -- The sandbox: no globals, no game API, data only.
    local sandbox =
        assert(FG.Import.Run("Pathwright.ok = _G == nil and print == nil and loadstring == nil and string == nil"))
    assert(sandbox.ok == true, "nothing but Pathwright in the sandbox")
    assert(FG.Import.Run("Pathwright.Guide = function() end") == nil, "functions refused")
    assert(FG.Import.Run("Pathwright.x = { [function() end] = 1 }") == nil, "functions as keys refused")
    assert(
        FG.Import.Run("os.exit(1)") == nil and FG.Import.Run(string.dump(function() end)) == nil,
        "no os, no bytecode"
    )
    -- Guides made by the upstream Factoruide app (`local FG = Factoruide`) are read as they are;
    -- their FactoruideSent (upstream's recordings) is not taken.
    local upstream, upstreamSent = FG.Import.Run(
        'local FG = Factoruide\nFG.Routes = FG.Routes or {}\nFG.Routes["up"] = { class = 8, steps = {} }\n'
            .. 'FactoruideSent = { ["Brouz-Realm"] = 9999 }\n'
    )
    assert(upstream and upstream.Routes.up and upstream.Routes.up.class == 8, "Factoruide guides read")
    assert(upstreamSent == nil, "FactoruideSent not taken")
    local sentBefore = PathwrightDB.sent["Brouz-Realm"]
    reloaded = false
    local upstreamLua = GuideLua("upstream-mage", 3000):gsub("local FG = Pathwright", "local FG = Factoruide")
        .. 'FactoruideSent = { ["Brouz-Realm"] = 9999 }\n'
    assert(not upstreamLua:find("Pathwright", 1, true), "the upstream text names Factoruide only")
    Click(Encode(upstreamLua))
    assert(
        reloaded and PathwrightDB.guides["upstream-mage"] and PathwrightDB.guides["upstream-mage"].created == 3000,
        "a Factoruide guide string imports: " .. status:GetText()
    )
    assert(PathwrightDB.sent["Brouz-Realm"] == sentBefore, "its FactoruideSent left out")
    PathwrightDB.guides["upstream-mage"] = nil
    -- WoW's integer formatter can be signed 32-bit even when Lua numbers hold wider masks.
    -- Exercise the pasted-string preparation path, then reload the text kept for that guide.
    local wide = Encode([[
Pathwright.Routes = {}
Pathwright.Routes["wide-numbers"] = {
    race = 7, class = 8, format = 2, created = 1000, version = 1,
    steps = {{ k = "reputation", rp = { sources = {{ eligibility = { race_mask = 8589934770 } }} } }},
    numbers = {2147483647, 2147483648, -2147483648, -2147483649, 4294967295,
        8589934770, -8589934770, 9007199254740991, 8589934770.25},
    [8589934770] = "wide numeric key",
}
]])
    local format = string.format
    string.format = function(pattern, ...)
        local value = ...
        if pattern == "%d" and type(value) == "number" and (value < -2147483648 or value > 2147483647) then
            error("integer overflow attempting to store " .. format("%.0f", value))
        end
        return format(pattern, ...)
    end
    local ok, pending, wideErr = pcall(FG.Import.Read, FG.Import, wide)
    string.format = format
    assert(ok and pending, "wide-number guide import: " .. tostring(wideErr or pending))
    local restored = assert(loadstring(pending.guides["wide-numbers"].text))()
    assert(restored.steps[1].rp.sources[1].eligibility.race_mask == 8589934770, "race mask remains a number")
    assert(restored[8589934770] == "wide numeric key", "wide numeric table key survives")
    local expected = {
        2147483647,
        2147483648,
        -2147483648,
        -2147483649,
        4294967295,
        8589934770,
        -8589934770,
        9007199254740991,
        8589934770.25,
    }
    for i, value in ipairs(expected) do
        assert(restored.numbers[i] == value, "wide-number save/reload preserves value " .. i)
    end
    -- Kept as Lua text: read back the same, a table inside itself refused.
    local value = { 1, nil, 'a\n"b"\0', x = 0.1, [1.5] = true, ["end"] = { -3, 1 / 3, 2 ^ 60 } }
    local back = assert(loadstring(assert(FG.Import.Serialize(value))))()
    assert(back[1] == 1 and back[2] == nil and back[3] == value[3] and back.x == 0.1 and back[1.5], "serialized")
    assert(back["end"][1] == -3 and back["end"][2] == 1 / 3 and back["end"][3] == 2 ^ 60, "numbers exact")
    local loop = {}
    loop.self = loop
    assert(FG.Import.Serialize(loop) == nil, "loops refused")

    -- Which guide a character follows. Only guides kept from here on (no files' guides).
    FG.Import.file = { routes = {}, assignments = {} }
    PathwrightDB.guides, PathwrightDB.guideAssignments = {}, nil
    FG.Import:Apply()
    useRoute(nil)
    assert(char.guide.route == nil, "no guide: none followed")
    -- The only guide made for its race and class: followed by itself.
    Click(Encode(GuideLua("solo", 2000) .. GuideLua("warrior", 2000, 1)))
    FG.Import:Apply()
    FG.Guide:FollowChoice()
    assert(char.guide.route == "solo", "the only gnome mage guide followed: " .. tostring(char.guide.route))
    -- A second one: the guide followed stays; without a choice, none until one is chosen.
    Click(Encode(GuideLua("duo", 2100)))
    FG.Import:Apply()
    FG.Guide:FollowChoice()
    assert(char.guide.route == "solo", "kept following the guide")
    useRoute(nil)
    assert(char.guide.route == nil, "two gnome mage guides: none chosen")
    -- The guides on the options' main page: the gnome mage's first, follow, start over, delete.
    FG.Options:Refresh()
    local rows = FG.Options:GuideRows()
    local function Row(name)
        for _, row in ipairs(rows) do
            if row.guide and row.guide.name == name and row:IsShown() then return row end
        end
    end
    assert(rows[1].guide.fits and rows[2].guide.fits and not rows[3].guide.fits, "this character's guides first")
    assert(Row("warrior").name:GetText():find("autre personnage", 1, true), "another character's guide")
    assert(Row("duo").details:GetText():find("niveaux 1%-60") and Row("duo").delete:IsShown(), "details")
    assert(not Row("duo").restart:IsShown(), "start over: the guide followed only")
    Row("duo").follow.OnClick(Row("duo").follow)
    assert(char.guide.route == "duo" and FG.Guide:Route() == FG.Routes.duo, "chosen in the list")
    assert(Row("duo").follow:GetText() == "Suivi" and not Row("duo").follow:IsEnabled(), "followed")
    assert(Row("solo").follow:GetText() == "Suivre" and Row("solo").follow:IsEnabled(), "another to follow")
    assert(Row("duo").restart:IsShown() and Row("duo").lit._shown, "the guide followed: lit, start over")
    calls.StaticPopup_Show = nil
    char.guide.skippedQuests[5004] = true
    Row("duo").restart.OnClick(Row("duo").restart)
    assert(calls.StaticPopup_Show and calls.StaticPopup_Show[1] == "PATHWRIGHT_RESET", "start over: asked")
    char.guide.skippedQuests[5004] = nil
    -- The choice is the character's, kept in its saved state.
    assert(PathwrightDB.characters["Brouz-Realm"].guide.route == "duo", "choice saved per character")
    FG.Guide:FollowChoice()
    assert(char.guide.route == "duo", "and kept")
    -- Delete: asked first (the game's dialog); the guide followed gone, back to the automatic choice.
    calls.StaticPopup_Show = nil
    local delete = Row("duo").delete
    delete.OnClick(delete)
    local asked = calls.StaticPopup_Show
    assert(asked and asked[1] == "PATHWRIGHT_DELETE_GUIDE" and asked[2] == "duo", "asks first")
    assert(PathwrightDB.guides.duo, "not before the answer")
    StaticPopupDialogs.PATHWRIGHT_DELETE_GUIDE.OnAccept(nil, asked[4])
    assert(not PathwrightDB.guides.duo and not FG.Routes.duo and not Row("duo"), "deleted")
    assert(char.guide.route == "solo", "back to the only gnome mage guide: " .. tostring(char.guide.route))

    -- Pathwright_Data, written by the desktop app: its guides beside the imported ones, of two with
    -- the same name the one computed last. The profile part (Data.lua) only reads its sent seqs,
    -- as text; the guide part runs it (its memory counted to the guide part, not the profile's).
    local dataLua = GuideLua("solo", 5000)
        .. GuideLua("desk-mage", 5000):gsub("local FG = Pathwright\nFG.Routes = FG.Routes or {}\n", "")
        .. 'PathwrightSent = { ["Brouz-Realm"] = 170 }\nPathwright.Config = { compassShown = false }\n'
    local function LoadData(lua, when)
        PathwrightData, PathwrightDataTime = lua, when
        assert(loadfile("addon/Pathwright_Profile/Data.lua"))("Pathwright_Profile", FG)
        assert(PathwrightData == lua, "not run by the profile part, left to the guide part")
    end
    LoadData(dataLua, 6000)
    FG.Import:ApplySaved()
    assert(FG.Routes["desk-mage"] and FG.Routes.warrior and FG.Routes.solo.created == 5000, "union, newer data wins")
    assert(FG.Import.info.solo.source == "app" and FG.Import.info.warrior.source == "import", "sources")
    assert(PathwrightData == nil and FG.Import.data.time == 6000, "data run by the guide part, its text let go")
    assert(FG.DataSent["Brouz-Realm"] == 170, "its sent seqs read by the profile part")
    assert(FG:Get("compassShown") == true, "data's Config ignored")
    FG.Options:Refresh()
    assert(Row("desk-mage") and not Row("desk-mage").delete:IsShown(), "the app's guides are not deleted in game")
    assert(Row("desk-mage").details:GetText():find("géré par l'application", 1, true), "managed by the app")
    assert(not FG.Import:Delete("desk-mage"), "not even by name")
    LoadData(dataLua:gsub("= 5000", "= 10"), 10)
    FG.Import:ApplySaved()
    assert(FG.Routes.solo.created == 2000 and FG.Import.info.solo.source == "import", "newer import wins")
    -- A guide of Pathwright_Data made for a newer addon: left out, named for the login message.
    LoadData(
        GuideLua("desk-next", 5000) .. string.format('FG.Routes["desk-next"].format = %d\n', FG.Import.FORMAT + 1),
        6500
    )
    FG.Import:ApplySaved()
    assert(not FG.Routes["desk-next"] and FG.Import.tooNew[1] == "desk-next", "newer format left out")
    -- Data without `.created` (older apps): the time it was written.
    LoadData(plain:gsub("gnome%-mage", "old-desk"), 7000)
    FG.Import:ApplySaved()
    assert(FG.Import.info["old-desk"].created == 7000, "data's time")
    -- Data that is not data: nothing kept, the error counted.
    FG.Import.data = nil
    PathwrightData, PathwrightDataTime = "Pathwright.f = function() end", 3000
    assert(loadfile("addon/Pathwright_Profile/Data.lua"))("Pathwright_Profile", FG)
    FG.Import:ApplySaved()
    assert(FG.Import.data == nil and PathwrightData == nil, "functions refused in the data")
    assert(PathwrightDB.errors["Pathwright_Data: functions are not allowed"], "the error counted")

    -- An older app's text: the whole text kept before (guideImport) moves to one guide each, its
    -- assignments are the first choice of the characters they name when several guides fit.
    FG.Import.data = nil
    PathwrightDB.guideImport = { text = fixture:gsub("gnome%-mage", "old-mage"), time = 4000 }
    FG.Import:ApplySaved()
    assert(PathwrightDB.guideImport == nil and PathwrightDB.guides["old-mage"].created == 4000, "moved")
    assert(FG.Assignments["Brouz-Realm"] == "old-mage", "assignments kept")
    useRoute(nil)
    assert(char.guide.route == "old-mage", "two gnome mage guides: the one assigned")
    useRoute("solo")
    assert(char.guide.route == "solo", "a choice wins over the assignment")

    -- "Delete the imported guides": asked, then every imported guide deleted.
    calls.StaticPopup_Show = nil
    Press("clear")
    assert(calls.StaticPopup_Show and calls.StaticPopup_Show[1] == "PATHWRIGHT_CLEAR_GUIDES", "asked")
    assert(PathwrightDB.guides.solo, "not before the answer")
    StaticPopupDialogs.PATHWRIGHT_CLEAR_GUIDES.OnAccept()
    assert(Empty(PathwrightDB.guides) and not FG.Routes.solo and char.guide.route == nil, "imports cleared")
    local ok = pcall(Press, "clear")
    assert(not ok, "nothing left to delete: the button disabled")

    -- Empty generated files (the addon as published) and no import: a message, no guide.
    FG.Services, FG.Config = nil, nil
    FG.Import:Apply()
    local rendered
    local ui = FG.Guide:UI()
    local render = ui.Render
    ui.Render = function(self, view)
        rendered = view
        return render(self, view)
    end
    FG.Guide:FollowChoice()
    FG.Guide:Refresh()
    ui.Render = render
    assert(
        FG.Guide:Route() == nil and rendered and rendered.message == FG.Guide.L.noGuides,
        "no guide: use the web app"
    )
    FG.Guide:Advance()
    Press("next")
    print("guide import ok")
end
ExportImport()

-- The guides the released apps wrote (addon/tests/guides, one file per release whose guide
-- output changed, see its README): each still imported both ways (pasted, Pathwright_Data),
-- listed, followed from its first step shown, and walked through to its end without error.
local function ReleasedGuides()
    local deflate = LibStub("LibDeflate")
    local files = assert(loadfile("addon/tests/guides/index.lua"))()
    assert(#files > 0, "released guides listed")
    local level, quests, done = playerLevel, onQuest, completed
    local errors = {}
    for msg in pairs(PathwrightDB.errors or {}) do
        errors[msg] = true
    end
    for _, file in ipairs(files) do
        local lua = assert(io.open("addon/tests/guides/" .. file)):read("*a")
        local ns = assert(FG.Import.Run(lua), file .. " runs")
        local names = {}
        for name in pairs(ns.Routes) do
            names[#names + 1] = name
        end
        assert(#names > 0, file .. ": its guides")
        for _, way in ipairs({ "import", "app" }) do
            -- Only this guide.
            PathwrightDB.guides, PathwrightDB.guideExtras, PathwrightDB.guideAssignments = {}, nil, nil
            FG.Import.file, FG.Import.data = { routes = {}, assignments = {} }, nil
            if way == "import" then
                local text = "FGG1:" .. deflate:EncodeForPrint(deflate:CompressDeflate(lua))
                local count, err = FG.Import:FromString(text)
                assert(count == #names, file .. " pasted: " .. tostring(err))
            else
                PathwrightData, PathwrightDataTime = lua, 1700000000
                assert(loadfile("addon/Pathwright_Profile/Data.lua"))("Pathwright_Profile", FG)
            end
            FG.Import:ApplySaved()
            assert(way == "import" or FG.Import.data, file .. " in Pathwright_Data")
            local listed = {}
            for _, guide in ipairs(FG.Import:List()) do
                listed[guide.name] = guide
            end
            for _, name in ipairs(names) do
                local what = file .. " (" .. way .. ") " .. name
                assert(listed[name] and listed[name].source == way, what .. ": listed")
                -- A character at level 1 with no quest yet.
                playerLevel, onQuest, completed = 1, {}, {}
                local view
                local ui = FG.Guide:UI()
                local render = ui.Render
                ui.Render = function(self, v)
                    view = v
                    return render(self, v)
                end
                useRoute(name)
                local route = FG.Guide:Route()
                assert(route == FG.Routes[name] and char.guide.route == name, what .. ": followed")
                assert(char.guide.step == 1, what .. ": from its first step, not " .. char.guide.step)
                local first
                for _, task in ipairs(view and view.tasks or {}) do
                    if task.index == 1 then first = task end
                end
                assert(first and first.step == route.steps[1], what .. ": its first step shown")
                -- Its first quest accepted (or the next page): the guide moves on.
                local step = route.steps[1]
                if step.k == "accept" and step.q then
                    onQuest[step.q] = true
                    fire("QUEST_ACCEPTED", step.q)
                else
                    Press("next")
                end
                assert(char.guide.step > 1, what .. ": advanced")
                -- Page after page to its end.
                for _ = 1, #route.steps do
                    if char.guide.step > #route.steps then break end
                    local at = char.guide.step
                    Press("next")
                    assert(char.guide.step > at, what .. ": stuck at step " .. at)
                end
                assert(char.guide.step == #route.steps + 1 and view.message == FG.Guide.L.done, what .. ": to its end")
                ui.Render = render
            end
        end
    end
    for msg in pairs(PathwrightDB.errors or {}) do
        assert(errors[msg], "no error: " .. msg)
    end
    playerLevel, onQuest, completed = level, quests, done
    PathwrightDB.guides, PathwrightDB.guideExtras = {}, nil
    FG.Import.file, FG.Import.data = { routes = {}, assignments = {} }, nil
    FG.Import:ApplySaved()
    useRoute(nil)
    print("released guides ok: " .. #files)
end
ReleasedGuides()

-- The settings: their schema (addon/settings.json, written into SettingsSchema.lua), the window.
local function SettingsTest()
    local tool = assert(loadfile("addon/tools/settings.lua"))("module")
    local generated, current = tool.Compare()
    assert(generated == current, "SettingsSchema.lua differs from settings.json: luajit addon/tools/settings.lua")
    local schema = tool.Decode(assert(io.open("addon/settings.json")):read("*a"))
    local keys = {}
    for _, group in ipairs(schema.groups) do
        for _, section in ipairs(group.sections) do
            for _, option in ipairs(section.options) do
                keys[#keys + 1] = option
            end
        end
    end
    assert(#keys > 50, "every option read: " .. #keys)

    -- Nothing saved: the defaults; a saved value that does not fit: the default (numbers held
    -- within their bounds).
    PathwrightDB.settings = {}
    for _, option in ipairs(keys) do
        assert(FG:Get(option.key) == option.default, "default of " .. option.key)
    end
    PathwrightDB.settings = { scale = "big", guideMode = "weird", autoAccept = 1, trackerQuests = 99 }
    assert(FG:Get("scale") == 1 and FG:Get("guideMode") == "full" and FG:Get("autoAccept") == true, "bad values")
    assert(FG:Get("trackerQuests") == 35, "within bounds")
    -- What the tests before chose (the guide's mode, tabs...) is let go.
    PathwrightDB.settings = {}

    -- Settings kept before the window (PathwrightDB.ui) move over once.
    PathwrightDB.ui = { scale = 1.2, appGuideMode = "full", uiShown = false, compassShown = false }
    PathwrightDB.settings.scale, PathwrightDB.settings.compassShown = nil, nil
    FG.MoveOldSettings()
    assert(PathwrightDB.ui == nil and PathwrightDB.settings.scale == 1.2, "old settings moved")
    assert(PathwrightDB.settings.compassShown == false and PathwrightDB.settings.uiShown == nil, "not the session's")
    assert(PathwrightDB.settings.appGuideMode == nil, "nor the app's leftovers")
    FG:Save("scale", nil)
    FG:Save("compassShown", nil)

    -- The addon's category in the game's options (AddOns), its pages registered with it.
    local category = options.Category()
    assert(category and category.registered and category.frame, "a canvas page in the game's options (AddOns)")
    local pages = {}
    for _, page in ipairs(category.subcategories) do
        pages[#pages + 1] = page.name
    end
    assert(
        table.concat(pages, ",") == "Affichage,Navigation,Automatisation,Conseils,Immersion,Avancé",
        "a page per group, then Advanced: " .. table.concat(pages, ",")
    )
    -- `/pw`, with anything after it: opens the options on the addon's page, nothing else happens.
    local function Now()
        return table.concat({
            tostring(FG:Get("guideMode")),
            tostring(FG:Get("uiShown")),
            tostring(FG:Get("lockFrames")),
            tostring(FG:Get("compassShown")),
            tostring(FG:Get("waypoints")),
            tostring(FG:Get("scale")),
            tostring(PathwrightDB.debug),
            tostring(char.guide.step),
            tostring(#char.events),
            tostring(FG.TextWindow:Parts() and FG.TextWindow:Parts():IsShown()),
        }, " ")
    end
    local before = Now()
    reloaded = false
    for _, old in ipairs({ "", "config", "hide", "next", "skip", "mode", "route x", "time", "reset", "export" }) do
        options.opened = nil
        SlashCmdList.PATHWRIGHT(old)
        assert(options.opened == category:GetID(), "/pw " .. old .. " opens the addon's options")
        assert(Now() == before and not reloaded, "/pw " .. old .. " does nothing else: " .. Now())
    end
    assert(SLASH_PATHWRIGHT2 == "/pathwright", "/factoruide too")
    -- The guide's options button too; in combat the game refuses: said in the chat instead.
    options.opened = nil
    FG:OpenSettings()
    assert(options.opened == category:GetID(), "the guide's options button")
    options.opened = nil
    InCombatLockdown = function() return true end
    local said
    local realPrint = print
    print = function(text) said = text end
    SlashCmdList.PATHWRIGHT("")
    print = realPrint
    InCombatLockdown = function() return false end
    assert(options.opened == nil and said and said:find("combat", 1, true), "in combat: a message")

    -- Every option of the schema is a control of its group's page (those of this edition), under
    -- its section's header, and the language.
    local controls, headers = {}, {}
    for _, page in ipairs(category.subcategories) do
        for _, init in ipairs(page.initializers) do
            local setting = init.data.setting
            if setting then
                controls[setting.variable:gsub("^Pathwright_", "")] = init
                assert(setting.category == page, "the setting of its page")
            elseif init.data.kind == "header" then
                headers[init.data.name] = page.name
            end
        end
    end
    local KINDS = { bool = "checkbox", number = "slider", select = "dropdown" }
    for _, group in ipairs(FG.SettingsSchema) do
        for _, section in ipairs(group.sections) do
            for _, option in ipairs(section.options) do
                local control = controls[option.key]
                if not option.only or option.only == FG.Edition then
                    assert(control and control.data.kind == KINDS[option.kind], "no control for " .. option.key)
                    assert(control.data.name == FG.T(option.label), "label translated: " .. control.data.name)
                    assert(control.data.setting.default == option.default, "default of " .. option.key)
                    if option.help then
                        assert(control.data.tooltip:find(FG.T(option.help), 1, true), "help of " .. option.key)
                    end
                    if section.title then
                        assert(headers[FG.T(section.title)] == FG.T(group.title), "section " .. section.title)
                    end
                else
                    assert(not control, "control of another edition: " .. option.key)
                end
            end
        end
    end
    assert(controls.autoAccept.data.name == "Accepter les quêtes automatiquement", "labels translated")
    assert(controls.locale and controls.locale.data.kind == "dropdown", "the language's control")
    assert(controls.debug, "the debug messages' check box (Advanced)")

    -- A check box: its setting reads FG:Get, writes FG:Save (saved, applied at once; the default
    -- saves nothing).
    local autoAccept = Option("Pathwright_autoAccept")
    assert(autoAccept:GetValue() == true, "read")
    autoAccept:SetValue(false)
    assert(PathwrightDB.settings.autoAccept == false and FG:Get("autoAccept") == false, "unchecked: saved")
    calls.AcceptQuest = nil
    fire("QUEST_DETAIL", 0)
    assert(not calls.AcceptQuest, "applied at once")
    autoAccept:SetValueToDefault()
    assert(PathwrightDB.settings.autoAccept == nil and FG:Get("autoAccept") == true, "the default: nothing saved")
    -- A number: a slider within its bounds, on its steps; a percent shown as such.
    local scale = controls.scale.data.options
    assert(scale.minValue == 0.6 and scale.maxValue == 2 and math.abs(scale.steps - 28) < 1e-9, "the size's slider")
    local label = scale.formatters[MinimalSliderWithSteppersMixin.Label.Right]
    assert(label(0.95) == "95%", "size in percent: " .. label(0.95))
    Option("Pathwright_scale"):SetValue(0.95000001)
    assert(FG:Get("scale") == 0.95 and PathwrightDB.settings.scale == 0.95, "on its steps")
    Option("Pathwright_trackerQuests"):SetValue(9)
    assert(FG:Get("trackerQuests") == 9, "number saved")
    assert(controls.trackerQuests.data.options.formatters[MinimalSliderWithSteppersMixin.Label.Right](9) == "9", "9")
    Option("Pathwright_scale"):SetValueToDefault()
    Option("Pathwright_trackerQuests"):SetValueToDefault()
    -- A select: a drop-down of its choices, translated.
    local styles = controls.pathMode.data.options()
    assert(#styles == 3 and styles[2].value == "on" and styles[2].label == "Toujours", "the choices")
    Option("Pathwright_pathMode"):SetValue("on")
    assert(FG:Get("pathMode") == "on" and Option("Pathwright_pathMode"):GetValue() == "on", "select saved")
    Option("Pathwright_pathMode"):SetValueToDefault()
    -- Requires: under the setting it needs, greyed while it is off.
    assert(controls.trackerQuests.parent == controls.trackerShown, "under the setting it needs")
    assert(controls.trackerQuests:Enabled(), "enabled while the tracker is on")
    Option("Pathwright_trackerShown"):SetValue(false)
    assert(not controls.trackerQuests:Enabled() and not controls.replaceTracker:Enabled(), "greyed while off")
    Option("Pathwright_trackerShown"):SetValueToDefault()
    assert(controls.trackerQuests:Enabled(), "back")
    Option("Pathwright_pathMode"):SetValue("off")
    assert(not controls.pathMap:Enabled(), "a select turned off greys too")
    Option("Pathwright_pathMode"):SetValueToDefault()
    -- Applied after a /reload only: said in its help; the game's dialog offers to reload, once for
    -- changes made together.
    assert(controls.uiTheme.data.tooltip:find("/reload", 1, true), "the help says /reload")
    runTimers()
    calls.StaticPopup_Show = nil
    local asked = 0
    StaticPopup_Show = function(which)
        if which == "PATHWRIGHT_RELOAD" then asked = asked + 1 end
    end
    Option("Pathwright_autoAccept"):SetValue(false)
    runTimers()
    assert(asked == 0, "no reload for a setting applied at once")
    Option("Pathwright_autoAccept"):SetValueToDefault()
    Option("Pathwright_uiTheme"):SetValue("parchemin")
    Option("Pathwright_suiteSkin"):SetValue(not FG:Get("suiteSkin"))
    assert(PathwrightDB.settings.uiTheme == "parchemin" and asked == 0, "theme saved, asked after the changes")
    runTimers()
    assert(asked == 1, "asked once: " .. asked)
    StaticPopupDialogs.PATHWRIGHT_RELOAD.OnAccept()
    assert(reloaded, "the interface reloads")
    reloaded = false
    Option("Pathwright_uiTheme"):SetValueToDefault()
    Option("Pathwright_suiteSkin"):SetValueToDefault()
    runTimers()
    StaticPopup_Show = record("StaticPopup_Show")
    -- The language: the game's, then each language.
    local languages = controls.locale.data.options()
    assert(languages[1].value == "" and languages[1].label:find("Français", 1, true), "the game's first")
    assert(#languages == #FG.LANGUAGES + 1, "then every language")
    Option("Pathwright_locale"):SetValue("enUS")
    assert(PathwrightDB.settings.locale == "enUS" and FG.Lang() == "enUS", "language chosen")
    Option("Pathwright_locale"):SetValue("")
    assert(PathwrightDB.settings.locale == nil and FG.Lang() == "frFR", "the game's again")
    -- Changed elsewhere (a key binding): the options show it; written by its own control: no
    -- notice back to it.
    options.notified = {}
    Press("mode")
    assert(options.notified.Pathwright_guideMode == 1, "the options told of the change")
    Option("Pathwright_guideMode"):SetValue("full")
    assert(options.notified.Pathwright_guideMode == 1, "not for the control's own change")
    -- The buttons beside their settings.
    local function After(key)
        for _, page in ipairs(category.subcategories) do
            for i, init in ipairs(page.initializers) do
                if init.data.setting and init.data.setting.variable == "Pathwright_" .. key then
                    return page.initializers[i + 1].data
                end
            end
        end
    end
    assert(
        After("toolstripTrash").name == "Remettre la barre d'outils en place",
        "the toolstrip's button: " .. After("toolstripTrash").name
    )
    assert(After("compassShown").name == "Remettre la boussole en haut", "the compass's button")

    -- The key bindings: each has its name (translated) and does what it says.
    local names = 0
    for name in pairs(options.bindings) do
        local global = _G["BINDING_NAME_" .. name]
        assert(type(global) == "string" and global ~= "", "no name for the binding " .. name)
        names = names + 1
    end
    assert(names == 16, "the bindings: " .. names)
    -- In their own category of the game's key bindings, a header per group (Zygor's way).
    local xml = assert(io.open("addon/Pathwright_Guide/Bindings.xml")):read("*a")
    local tags, inCategory = 0, 0
    for tag in xml:gmatch("<Binding [^>]+>") do
        tags = tags + 1
        if tag:find('category="Pathwright"', 1, true) then inCategory = inCategory + 1 end
    end
    assert(tags == 16 and inCategory == 16, "every binding in the Pathwright category")
    assert(xml:find('<Binding name="PATHWRIGHT_NEXT" header="PATHWRIGHT"', 1, true), "the guide's header")
    assert(
        xml:find('<Binding name="CLICK PWStrip1:LeftButton" header="PATHWRIGHTTOOLSTRIP"', 1, true),
        "the toolstrip's"
    )
    assert(
        BINDING_HEADER_PATHWRIGHT == "Guide" and BINDING_HEADER_PATHWRIGHTTOOLSTRIP == "Barre d'outils",
        "headers named"
    )
    assert(BINDING_NAME_PATHWRIGHT_NEXT == "Étape suivante", "translated: " .. BINDING_NAME_PATHWRIGHT_NEXT)
    options.opened = nil
    Key("PATHWRIGHT_OPTIONS")
    assert(options.opened == category:GetID(), "a key opens the options")
    local shown = FG:Get("guideShown")
    Key("PATHWRIGHT_GUIDE")
    assert(FG:Get("guideShown") == not shown and PathwrightDB.settings.guideShown == not shown, "the guide hidden")
    Key("PATHWRIGHT_GUIDE")
    assert(FG:Get("guideShown") == shown, "and shown")
    FG:Save("guideShown", nil)
    FG:Save("guideMode", nil)
    -- Nothing left over: every setting back to its default.
    for _, option in ipairs(keys) do
        assert(PathwrightDB.settings[option.key] == nil, "left saved: " .. option.key)
    end
    for msg in pairs(PathwrightDB.errors or {}) do
        assert(not msg:find("Settings", 1, true), "no error: " .. msg)
    end
    print("settings ok")
end
SettingsTest()

local function GuideSelectionTest()
    local list = FG.Import.List
    local guides = {}
    local function add(name, source, first, last, fits, origin)
        guides[#guides + 1] = {
            name = name,
            source = source,
            fits = fits,
            route = { fromLevel = first, toLevel = last, origin = origin, steps = {} },
        }
    end
    add("RestedXP personal copy", "import", 10, 60, true)
    add("Desktop", "app", 1, 60, true)
    add("Arathi", "builtin", 38, 39, true)
    add("Unknown levels", "builtin", nil, nil, true)
    add("Short route", "builtin", 38, 38, true)
    add("Another route", "builtin", 38, 39, true)
    for i = 12, 1, -1 do
        add("Pack / Route " .. i, "builtin", i + 29, i + 31, i % 2 == 0, "RXPGuides / Pack")
    end
    FG.Import.List = function() return guides end
    local function switch(bar, text)
        local prefix = text .. " ("
        for _, b in ipairs(frames) do
            if b:GetParent() == bar and type(b:GetText()) == "string" and b:GetText():sub(1, #prefix) == prefix then
                b.OnClick(b)
                return
            end
        end
        error("missing section " .. text)
    end
    local function typeIn(box, text)
        box:SetText(text)
        box.OnTextChanged(box, true)
    end
    FG.Options:Refresh()
    FG.GuideBrowser:Toggle()
    for _, name in ipairs({ "PathwrightSettingsGuideFilters", "PathwrightBrowserGuideFilters" }) do
        local bar = named(name)
        switch(bar, "RestedXP")
        assert(#bar:Results() == 12 and FG.Options.GuideTitle(bar:Results()[1]) == "Route 1")
        if name == "PathwrightSettingsGuideFilters" then
            local block, rows = bar:GetParent(), FG.Options:GuideRows()
            local height
            block.SetHeight = function(_, h) height = h end
            block:Refresh(244)
            assert(rows[3]:IsShown() and not rows[4]:IsShown() and height <= 244, "three rows and pager fit")
            block:Refresh(450)
            assert(rows[8]:IsShown() and height <= 450, "larger panel fits eight rows and pager")
            block.SetHeight = nil
        end
        typeIn(bar.level, "38")
        assert(#bar:Results() == 3, "both boundaries of a guide's levels included")
        typeIn(bar.level, "37-39")
        assert(#bar:Results() == 5, "guides overlapping the requested range")
        bar.mine.GetChecked = function() return true end
        bar.mine.OnClick(bar.mine)
        assert(#bar:Results() == 3)
        typeIn(bar.search, "rOuTe 8")
        assert(#bar:Results() == 1 and bar:Results()[1].name == "Pack / Route 8")
        switch(bar, FG.T("Imported"))
        assert(#bar:Results() == 2 and bar.level:GetText() == "", "imported and desktop guides share a section")
        switch(bar, FG.T("Default"))
        local defaults = bar:Results()
        assert(#defaults == 4 and defaults[1].name == "Short route" and defaults[2].name == "Another route")
        assert(defaults[3].name == "Arathi" and defaults[4].name == "Unknown levels")
        typeIn(bar.level, "60")
        assert(#bar:Results() == 0)
        switch(bar, "RestedXP")
        assert(bar.level:GetText() == "37-39" and #bar:Results() == 1, "section filters restored")
    end
    FG.GuideBrowser:Toggle()
    FG.Import.List = list
    print("guide sections and filters ok")
end
GuideSelectionTest()

-- The way on foot found in game: the walkable ground (Terrain/*.lua, as the release ships it),
-- a walk on it around the steep ground and through a lift, the planned walk joined, and the
-- guide's pathing taking the way found from where the character stands. (In a function: the
-- file has its 200 locals.)
WalkerTest = function()
    local Terrain, Walker, Pathing = FG.Terrain, FG.Walker, FG.Pathing
    assert(not Terrain.Has(1), "no ground before its files are loaded")
    local list = io.popen("ls addon/Pathwright_Guide/Terrain")
    local names = {}
    for name in list:lines() do
        if name:match("^Tiles%d+%.lua$") then names[#names + 1] = name end
    end
    list:close()
    table.sort(names, function(a, b) return tonumber(a:match("%d+")) < tonumber(b:match("%d+")) end)
    assert(names[1] == "Tiles0.lua" and #names > 1, "the ground's files, the first one first")
    for _, name in ipairs(names) do
        assert(loadfile("addon/Pathwright_Guide/Terrain/" .. name))()
    end
    assert(loadfile("addon/Pathwright_Guide/Terrain/Passages.lua"))()
    Terrain.maps = nil
    assert(Terrain.Has(0) and Terrain.Has(1) and not Terrain.Has(530), "the continents whose ground is known")
    -- Every tile reads: its format, its floors counted as its records are.
    local read = 0
    for key in pairs(FG.TerrainData) do
        local map, tr, tc = key:match("^(%d+):(%d+):(%d+)$")
        if (tonumber(tr) + tonumber(tc)) % 7 == 0 then
            assert(Terrain.Tile(tonumber(map), tonumber(tr), tonumber(tc)), "tile " .. key .. " reads")
            read = read + 1
        end
    end
    assert(read > 100 and Terrain.Kept() <= 80, "tiles read, the least used forgotten: " .. Terrain.Kept())
    Terrain.Forget()
    -- Durotar, Razor Hill to the south-west: the app walks 1385 yards around the steep ground
    -- (1002 straight).
    local from, to = { 292.6, -4712.0 }, { -588.7, -4236.1 }
    local route = assert(Walker.Solve({ map = 1, north = from[1], west = from[2], target = to }))
    assert(route.yards > 1300 and route.yards < 1480, "around the steep ground: " .. route.yards)
    local first, last = route.points[1], route.points[#route.points]
    assert(first[1] == from[1] and first[2] == from[2], "from where the character stands")
    assert(last[1] == to[1] and last[2] == to[2] and not route.join, "to the place itself")
    assert(#route.points > 4 and #route.points < 40, "a few turns, not every floor: " .. #route.points)
    local shortest = assert(Walker.Solve({ map = 1, north = from[1], west = from[2], target = to, weight = 1 }))
    assert(shortest.yards <= route.yards and shortest.yards < 1400, "the shortest way: " .. shortest.yards)
    -- Each leg of the way is walked in a line: its length is the way's, near enough.
    local length = 0
    for k = 1, #shortest.points - 1 do
        local a, b = shortest.points[k], shortest.points[k + 1]
        length = length + math.sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2)
    end
    assert(length <= shortest.yards + 20 and length > 1002, "drawn straighter than floor by floor: " .. length)
    -- Up to Thunder Bluff: the floors do not hold the lifts, the passage does (1682 in the app).
    local bluff = assert(Walker.Solve({ map = 1, north = -2112.5, west = -474.8, target = { -1267.5, 47.0 } }))
    assert(bluff.yards > 1500 and bluff.yards < 1900, "by the lift: " .. bluff.yards)
    -- No ground: another continent, the open sea.
    local none, why = Walker.Solve({ map = 530, north = 0, west = 0, target = { 10, 10 } })
    assert(none == nil and why == "nodata", "no ground known there")
    none, why = Walker.Solve({ map = 1, north = from[1], west = from[2], target = { 292, -9000 } })
    assert(none == nil and why == "offmesh", "a place off the floors: " .. tostring(why))
    -- A walk planned to the place is joined where that is the shortest: here one that passes
    -- beside the character and counts little from there.
    local joined = assert(Walker.Solve({
        map = 1,
        north = from[1],
        west = from[2],
        target = to,
        joins = { { 262.5, -4729.2, left = 50, leg = 3 } },
    }))
    assert(joined.join and joined.join.leg == 3 and joined.yards < 200, "the planned walk joined: " .. joined.yards)
    last = joined.points[#joined.points]
    assert(last[1] == 262.5 and last[2] == -4729.2, "its way ends on the join")
    -- A place in a cave (Skull Rock: four floors there, the hill and the cave's under it): the
    -- floor is the one the planned walk leads to, and from beside that walk the way joins it.
    local cave = { 1462.9, -4701.4 }
    local walkIn = { { 1188, -4629 }, { 1346, -4629 }, { 1396, -4679 }, { 1421, -4679 }, cave }
    local joins, left = {}, 0
    for k = #walkIn - 1, 1, -1 do
        local a, b = walkIn[k], walkIn[k + 1]
        left = left + math.sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2)
        table.insert(joins, 1, { a[1], a[2], left = left, leg = k })
    end
    local inside = assert(Walker.Solve({ map = 1, north = 1000, west = -4500, target = cave, joins = joins }))
    local total = inside.yards + (inside.join and inside.join.left or 0)
    assert(total > 480 and total < 620, "into the cave by its mouth: " .. total)
    local alone = assert(Walker.Solve({ map = 1, north = 1000, west = -4500, target = cave }))
    assert(math.abs(alone.yards - total) < 60, "as without a planned walk here: " .. alone.yards)
    -- A little every frame: the job ends, its way given once.
    local got, calls = nil, 0
    local job = Walker:Start({ map = 1, north = from[1], west = from[2], target = to }, function(r)
        got, calls = r, calls + 1
    end)
    local dropped = Walker:Start(
        { map = 1, north = from[1], west = from[2], target = to },
        function() calls = calls + 10 end
    )
    Walker:Cancel(dropped)
    assert(job and got == nil, "not found at once")
    Walker:Finish()
    assert(got and calls == 1 and math.abs(got.yards - route.yards) < 1, "found, the job given up not called")
    -- The guide's pathing: the tests' world is the map's fractions times 1000 on continent 0,
    -- real ground there (the Hillsbrad foothills). A place 350 yards away, a planned walk that
    -- starts elsewhere: the compass follows the way from where the character stands.
    ShortestPathForever = nil
    FG:Save("spfLink", nil)
    FG:Save("pathMode", nil)
    FG:Save("pathLive", nil)
    local place = { m = 1426, x = 40, y = 71.2, wp = { 299, 712, 299, 800, 400, 800 } }
    Pathing:SetTarget(place, place, { title = "The place", kind = "objective" })
    assert(
        Pathing:Aim(0, 100, 600) == nil and Pathing:LiveState().state == "searching",
        "far from the planned walk: looked for"
    )
    Walker:Finish()
    local state = Pathing:LiveState()
    assert(
        state.state == "found" and state.yards > 300 and state.yards < 500,
        "the way from here: " .. tostring(state.yards)
    )
    local n, w, back = Pathing:Aim(0, 100, 600)
    assert(n and n > 100 and w > 600 and not back, "the compass follows it from where the character stands")
    local left = Pathing:Remaining(0, 100, 600)
    local ends = left and left[#left]
    assert(
        ends and #left >= 2 and math.abs(ends[1] - 400) < 0.01 and math.abs(ends[2] - 712) < 0.01,
        "drawn to the place"
    )
    -- On the way: nothing looked for again. Off it: found again from there.
    local clock, now = GetTime, 5000
    GetTime = function() return now end
    Pathing:Aim(0, 101, 601)
    assert(Pathing:LiveState().state == "found", "on the way: kept")
    now = now + 10
    Pathing:Aim(0, 100, 660)
    assert(Pathing:LiveState().state == "searching", "off the way: looked for again")
    Walker:Finish()
    assert(Pathing:LiveState().state == "found", "and found from there")
    -- Turned off: the guide's planned walk, as before. (A setting changed draws the guide again,
    -- which points at its own step: the tests' place is set again.)
    FG:Save("pathLive", false)
    Pathing:SetTarget(place, place, { title = "The place", kind = "objective" })
    now = now + 10
    assert(
        Pathing:Aim(0, 100, 600) == nil and Pathing:LiveState().state == "none",
        "turned off: the planned walk alone"
    )
    n = Pathing:Aim(0, 299.3, 712)
    assert(n and math.abs(n - 299) < 1, "which is followed when close to it")
    FG:Save("pathLive", nil)
    Pathing:SetTarget(nil)
    GetTime = clock
    Terrain.Forget()
    print("walker ok")
end
WalkerTest()
WalkerTest = nil

-- A quest taken in a party is shared with it (Party.lua): when every member runs the addon, or
-- with any party when that is not asked for; not shared back, nor with members who have it.
ShareTest = function()
    local P = FG.Party
    local saved = {
        group = IsInGroup,
        raid = IsInRaid,
        members = GetNumSubgroupMembers,
        name = UnitName,
        chat = C_ChatInfo,
        push = QuestLogPushQuest,
        pushable = C_QuestLog.IsPushableQuest,
        index = C_QuestLog.GetLogIndexForQuestID,
        select = C_QuestLog.SetSelectedQuest,
        selected = C_QuestLog.GetSelectedQuest,
        combat = InCombatLockdown,
        time = GetTime,
    }
    local now = 5000
    GetTime = function() return now end
    local party = { party1 = "Pata Blue", party2 = "Zed" }
    UnitName = function(unit) return unit == "player" and "Brouz" or party[unit] end
    IsInGroup = function() return true end
    IsInRaid = function() return false end
    GetNumSubgroupMembers = function() return 2 end
    local groupMembers = GetNumGroupMembers
    GetNumGroupMembers = function() return 3 end
    local said = {}
    C_ChatInfo = { SendAddonMessage = function(prefix, text) said[#said + 1] = prefix .. " " .. text end }
    local pushed, selection = {}, 77
    QuestLogPushQuest = function(index) pushed[#pushed + 1] = { index = index, selected = selection } end
    C_QuestLog.IsPushableQuest = function(q) return q ~= 9902 end
    C_QuestLog.GetLogIndexForQuestID = function(q) return q >= 9900 and q - 9897 or nil end
    C_QuestLog.SetSelectedQuest = function(q) selection = q end
    C_QuestLog.GetSelectedQuest = function() return selection end
    InCombatLockdown = function() return false end
    local function hear(text, sender) fire("CHAT_MSG_ADDON", "PWSYNC1", text, "PARTY", sender) end
    local fired = fire
    local function saidText(text)
        for _, m in ipairs(said) do
            if m == "PWSYNC1 " .. text then return true end
        end
        return false
    end
    runTimers()
    P.users, P.progress = {}, {}
    said = {}

    -- Nobody known to run the addon: asked on a roster change, and nothing shared.
    fired("GROUP_ROSTER_UPDATE")
    runTimers()
    assert(saidText("!?"), "who runs the addon is asked")
    assert(not P:Everyone() and not P:Uses("Pata Blue"))
    local shared, why = P:Share(9900)
    assert(not shared and why == "members", "not shared while a member does not run the addon: " .. tostring(why))

    -- One of two answered: still not everyone. Names are matched whatever the realm and the spaces.
    hear("!", "Pata Blue-Realm")
    assert(P:Uses("Pata Blue") and P:Uses("Pata") and not P:Everyone())
    -- A member asking says that it runs the addon, and is answered.
    said = {}
    hear("!?", "Zed-Realm")
    runTimers()
    assert(P:Everyone(), "everyone runs the addon")
    assert(saidText("!"), "a member who asks is answered")
    -- Our own message coming back (under our whole name on WoW Forever) is not a member's.
    assert(P.Own("Brouz") and P.Own("Brouz Red") and not P.Own("Pata Blue"))

    -- A quest taken: the party is told, and it is shared a moment later, the log's selection put back.
    said, pushed = {}, {}
    fired("QUEST_ACCEPTED", 9900)
    assert(saidText("A:9900"), "the party is told the quest was taken")
    assert(#pushed == 0, "not shared before the members could say they took it too")
    runTimers()
    assert(#pushed == 1 and pushed[1].index == 3 and pushed[1].selected == 9900, "the quest is shared")
    assert(selection == 77, "the log's selection is put back")
    assert(saidText("P:9900"), "the members are told it was shared")
    -- Classic Era and TBC pass the log's index first.
    pushed = {}
    fired("QUEST_ACCEPTED", 4, 9901)
    runTimers()
    assert(#pushed == 1 and pushed[1].index == 4, "the quest id is the second argument on Classic")

    -- A quest the game does not let share is not, and the party is not told it was.
    said, pushed = {}, {}
    fired("QUEST_ACCEPTED", 9902)
    runTimers()
    assert(#pushed == 0 and not saidText("P:9902"), "an unshareable quest is left alone")

    -- A quest a member shared with us is not shared back.
    pushed = {}
    hear("P:9903", "Zed")
    fired("QUEST_ACCEPTED", 9903)
    runTimers()
    assert(#pushed == 0, "not shared back")
    shared, why = P:Share(9903)
    assert(why == "offered", tostring(why))
    now = now + 400
    hear("A:9903", "Pata Blue")
    shared, why = P:Share(9903)
    assert(why == "have", "every member has it: " .. tostring(why))

    -- Members who took it at the same quest giver, or whose progress holds it, are not offered it.
    pushed = {}
    hear("A:9904", "Zed")
    P:Store("Pata Blue", 9904, { "0" })
    fired("QUEST_ACCEPTED", 9904)
    runTimers()
    assert(#pushed == 0, "everyone has the quest already")
    P:Forget("Pata Blue", 9904)
    shared = P:Share(9904)
    assert(shared and #pushed == 1, "shared when one member lacks it")

    -- In a fight: after it.
    pushed = {}
    InCombatLockdown = function() return true end
    shared, why = P:Share(9905)
    assert(not shared and why == "combat" and #pushed == 0)
    InCombatLockdown = function() return false end
    fired("PLAYER_REGEN_ENABLED")
    assert(#pushed == 1 and pushed[1].index == 8, "shared after the fight")

    -- A member without the addon: only when the setting does not ask for all.
    party.party2 = "Nob"
    pushed = {}
    fired("QUEST_ACCEPTED", 9906)
    runTimers()
    assert(#pushed == 0, "a member without the addon: not shared")
    FG:Save("questShareAll", false)
    fired("QUEST_ACCEPTED", 9906)
    runTimers()
    assert(#pushed == 1, "shared with any party when not asked for all")
    -- Turned off: nothing shared, the party still told the quest was taken.
    FG:Save("questShare", false)
    said, pushed = {}, {}
    fired("QUEST_ACCEPTED", 9907)
    runTimers()
    assert(#pushed == 0 and saidText("A:9907"), "turned off")
    shared, why = P:Share(9907)
    assert(why == "off")
    FG:Save("questShare", true)
    FG:Save("questShareAll", true)

    -- A raid, or no party: nothing, and who ran the addon is forgotten on leaving.
    IsInRaid = function() return true end
    shared, why = P:Share(9908)
    assert(why == "alone")
    IsInRaid = function() return false end
    IsInGroup = function() return false end
    GetNumSubgroupMembers = function() return 0 end
    fired("GROUP_ROSTER_UPDATE")
    local known = 0
    for _ in pairs(P.users) do
        known = known + 1
    end
    assert(known == 0, "forgotten on leaving the party")
    P:Say()

    IsInGroup, IsInRaid, GetNumSubgroupMembers, UnitName = saved.group, saved.raid, saved.members, saved.name
    C_ChatInfo, QuestLogPushQuest, InCombatLockdown, GetTime = saved.chat, saved.push, saved.combat, saved.time
    C_QuestLog.IsPushableQuest, C_QuestLog.GetLogIndexForQuestID = saved.pushable, saved.index
    C_QuestLog.SetSelectedQuest, C_QuestLog.GetSelectedQuest = saved.select, saved.selected
    P.progress = {}
    runTimers()
    GetNumGroupMembers = groupMembers
    print("share ok")
end
ShareTest()
ShareTest = nil

-- The danger alerts (Safety.lua) are for the open world: an elite target and low health warn
-- there, and neither does in instanced content. (In a function: the file has its 200 locals.)
SafetyTest = function()
    local saved = {
        UIErrorsFrame = UIErrorsFrame,
        IsInInstance = IsInInstance,
        UnitExists = UnitExists,
        UnitIsDead = UnitIsDead,
        UnitCanAttack = UnitCanAttack,
        UnitIsPlayer = UnitIsPlayer,
        UnitLevel = UnitLevel,
        UnitClassification = UnitClassification,
        UnitName = UnitName,
        UnitHealth = UnitHealth,
        UnitHealthMax = UnitHealthMax,
        UnitIsDeadOrGhost = UnitIsDeadOrGhost,
    }
    local said = {}
    UIErrorsFrame = { AddMessage = function(_, text) said[#said + 1] = text end }
    local inside, health = false, 100
    IsInInstance = function() return inside end
    UnitExists, UnitIsDead, UnitCanAttack =
        function() return true end, function() return false end, function() return true end
    UnitIsPlayer, UnitIsDeadOrGhost = function() return false end, function() return false end
    UnitLevel = function(unit) return unit == "player" and 20 or 22 end
    UnitClassification, UnitName = function() return "elite" end, function() return "Mogrosh Brute" end
    UnitHealth, UnitHealthMax = function() return health end, function() return 100 end
    local function Health(now)
        health = now
        fire("UNIT_HEALTH", "player")
    end

    fire("PLAYER_TARGET_CHANGED")
    assert(#said == 1 and said[1]:find("Mogrosh Brute", 1, true), "an elite target warns in the open world")
    Health(100) -- whatever the tests before left: not warned yet
    Health(20)
    assert(#said == 2 and said[2]:find("20", 1, true), "low health warns in the open world")
    Health(100)

    inside = true
    fire("PLAYER_TARGET_CHANGED")
    Health(20)
    assert(#said == 2, "no warning in instanced content: " .. tostring(said[3]))
    Health(100)

    inside = false
    fire("PLAYER_TARGET_CHANGED")
    Health(20)
    assert(#said == 4, "back in the open world, both warn again")
    Health(100)
    FG:Save("safetyAlerts", false)
    fire("PLAYER_TARGET_CHANGED")
    Health(20)
    assert(#said == 4, "nothing when the alerts are off")
    FG:Save("safetyAlerts", nil)
    Health(100)

    for name in pairs(saved) do
        _G[name] = saved[name]
    end
    for _, name in ipairs({ "UnitHealth", "UnitHealthMax", "UnitIsDeadOrGhost", "UIErrorsFrame" }) do
        if saved[name] == nil then _G[name] = nil end
    end
    print("danger alerts ok")
end
SafetyTest()
SafetyTest = nil

-- A UI suite writes its font on a text itself, which pins it: the font chosen in the settings is
-- then written on the text too, and the suite's comes back with the default. Last: once a suite
-- is ready the addon's windows have its look. (In a function: the file has its 200 locals.)
local function SuiteFontTest()
    local Skin = FG.Skin
    local facade = {
        Font = function(fs)
            local _, size = fs:GetFont()
            fs:SetFont("Suite.ttf", size, "")
        end,
    }
    FG:Save("suiteSkin", true)
    EllesmereUI.skin(setmetatable(facade, {
        __index = function()
            return function() end
        end,
    }))
    assert(Skin:Suite() == "EllesmereUI", "the suite is ready")
    local text = { size = 12 }
    function text:GetFont() return self.path, self.size, self.flags end
    function text:SetFont(path, size, flags)
        self.path, self.size, self.flags = path, size, flags
        return true
    end
    function text:SetFontObject() end -- pinned: a font object no longer changes it
    Skin:Font(text)
    assert(text.path == "Suite.ttf" and text.size == 12, "the suite's font by default")
    -- A row of the guide drawn smaller (the party line shrunk to fit, a "mobs on the way" row).
    Skin:Resize(text, 9)
    assert(text.path == "Suite.ttf" and text.size == 9, "a pinned text still takes another size")
    text.path = nil
    Skin:Resize(text, 9)
    assert(text.path == nil, "the size it has: nothing written")
    Skin:Resize(text, 12)
    assert(text.path == "Suite.ttf" and text.size == 12, "and back")
    local locale = GetLocale
    GetLocale = function() return "enUS" end
    FG:Save("uiFont", "Morpheus")
    assert(text.path == "Fonts\\MORPHEUS.TTF" and text.size == 12, "the font chosen, written over the suite's")
    FG:Save("uiFont", nil)
    assert(text.path == "Suite.ttf", "and the suite's again with the default")
    GetLocale = locale
    FG:Save("suiteSkin", nil)
    print("suite font ok")
end
SuiteFontTest()
