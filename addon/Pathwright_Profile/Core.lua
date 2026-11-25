-- The addon comes in two parts sharing this namespace (the global `Pathwright`): Pathwright_Profile
-- (this core, the recordings and the character's profile, always installed) and Pathwright_Guide
-- (the guide and everything around it, which depends on it).
local addonName, FG = ...
_G.Pathwright = FG

FG.DB_VERSION = 1

-- Texts in the language chosen in the addon's settings (`locale`, PathwrightDB.settings), else the
-- game's; the English text when there is no translation. The files of Locales/ fill
-- FG.Locales[locale] = { [English text] = translation }.
FG.Locales = {}

-- The languages the addon can be set to (its options, Display page), besides the game's.
FG.LANGUAGES = { "enUS", "frFR", "deDE", "esES", "esMX", "ptBR", "ruRU", "koKR", "zhCN", "zhTW" }
local known = {}
for _, lang in ipairs(FG.LANGUAGES) do
    known[lang] = true
end

--- The language chosen in the settings, nil for the game's.
function FG.ChosenLang()
    local settings = type(PathwrightDB) == "table" and PathwrightDB.settings
    local lang = type(settings) == "table" and settings.locale
    return known[lang] and lang or nil
end

--- The addon's language (a game locale: "frFR", "deDE"...).
function FG.Lang()
    local lang = FG.ChosenLang() or (GetLocale and GetLocale()) or "enUS"
    if lang == "esMX" and not FG.Locales.esMX then return "esES" end
    return lang
end

--- `text` (English) in the addon's language.
function FG.T(text)
    local strings = FG.Locales[FG.Lang()]
    return strings and strings[text] or text
end

--- Game version of the client: forever (1.16+ builds), classic (1.15), tbc (2.x).
FG.Edition = (function()
    local major, minor = (GetBuildInfo and GetBuildInfo() or "1.60"):match("^(%d+)%.(%d+)")
    major, minor = tonumber(major), tonumber(minor)
    if major == 2 then
        return "tbc"
    elseif major == 1 and minor and minor < 16 then
        return "classic"
    end
    return "forever"
end)()

local frame = CreateFrame("Frame")
FG.frame = frame
local handlers = {}

--- Register a handler for an event; several modules may listen to the same event.
function FG:On(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        frame:RegisterEvent(event)
    end
    table.insert(handlers[event], fn)
end

--- Count an error in the saved variables (`PathwrightDB.errors`, message -> count): a few short
--- messages, so what fails on one client shows up in its SavedVariables.
local MAX_ERRORS = 20
function FG:Error(where, err)
    local msg = (where .. ": " .. tostring(err)):gsub("Interface[/\\]AddOns[/\\]Pathwright[%w_]*[/\\]", ""):sub(1, 200)
    self:Debug("error in %s", msg)
    if type(PathwrightDB) ~= "table" then return end
    local errors = PathwrightDB.errors or {}
    PathwrightDB.errors = errors
    if errors[msg] then
        errors[msg] = errors[msg] + 1
        return
    end
    local n = 0
    for _ in pairs(errors) do
        n = n + 1
    end
    if n < MAX_ERRORS then errors[msg] = 1 end
end

--- Call `fn` under pcall, errors counted (event handlers, timers).
function FG:Try(where, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then self:Error(where, err) end
end

frame:SetScript("OnEvent", function(_, event, ...)
    for _, fn in ipairs(handlers[event]) do
        FG:Try(event, fn, ...)
    end
end)

function FG:Print(fmt, ...) print("|cff33ccffPathwright|r: " .. string.format(fmt, ...)) end

function FG:Debug(fmt, ...)
    if PathwrightDB and PathwrightDB.debug then self:Print(fmt, ...) end
end

--- Values can be "secret" (unreadable by addons) in restricted contexts such as combat.
function FG.Readable(v)
    if v == nil or (issecretvalue and issecretvalue(v)) then return nil end
    return v
end

--- Anchor a frame by its top left corner where it is now, so it grows and shrinks downwards
--- (the buttons of its header stay under the mouse); returns the point to save, nil when the
--- frame has no position yet. The game re-anchors a dragged frame to its closest corner or
--- edge, which can be the bottom.
--- Whether a frame can be moved, resized or shown now. A secure button hanging on it (a quest
--- item button), or on a frame anchored to it, makes it protected: during combat the game blocks
--- these changes ("blocked from an action only available to the Blizzard UI"), so they wait for
--- the end of the fight.
function FG.CanLayout(frame) return not (InCombatLockdown() and frame:IsProtected()) end

--- Whether our frames may be put on a nameplate: not on a forbidden one (in instances, some
--- friendly plates), which takes nothing of ours. Others take our marks even when the game
--- restricts measuring them (see FG.PlateMeasurable).
function FG.PlateUsable(plate)
    if not plate then return false end
    return not (plate.IsForbidden and plate:IsForbidden() == true)
end

--- Whether a nameplate's place on screen may be read (GetCenter): not when forbidden, nor when
--- the game restricts it ("Can't measure restricted regions").
function FG.PlateMeasurable(plate)
    if not FG.PlateUsable(plate) then return false end
    return not (plate.IsAnchoringRestricted and plate:IsAnchoringRestricted() == true)
end

-- Name the function the game refused to us (the popup does not), once each, with where it came from.
local blocked = {}
for _, event in ipairs({ "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN" }) do
    FG:On(event, function(addon, func)
        if type(addon) ~= "string" or not addon:find("^Pathwright") or blocked[func] then return end
        blocked[func] = true
        FG:Print("%s: %s", event, tostring(func))
        if debugstack then print(debugstack(2, 6, 0)) end
    end)
end

function FG.PinTopLeft(frame)
    local left, top = frame:GetLeft(), frame:GetTop()
    if not left or not top then return nil end
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    return { "TOPLEFT", "UIParent", "BOTTOMLEFT", left, top }
end

--- Pin a frame by its top (see `FG.PinTopLeft`) when it is anchored by its bottom or center,
--- as positions saved before were; returns the point to save, or nil when nothing changed.
function FG.PinTopIfNeeded(frame)
    local point = frame:GetPoint()
    if not point or point:find("^TOP") then return nil end
    return FG.PinTopLeft(frame)
end

--- Spell name in the game's language (nil when unknown).
function FG.SpellName(id)
    if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) end
    return GetSpellInfo and (GetSpellInfo(id))
end

--- Item info, from C_Item or the older globals.
function FG.ItemInfo(item)
    if C_Item and C_Item.GetItemInfo then return C_Item.GetItemInfo(item) end
    return GetItemInfo(item)
end

--- How many of an item the character has in its bags (and its bank with `includeBank`, as the
--- game last saw it).
function FG.ItemCount(item, includeBank)
    if C_Item and C_Item.GetItemCount then return C_Item.GetItemCount(item, includeBank) end
    return GetItemCount(item, includeBank)
end

function FG.ItemInfoInstant(item)
    if C_Item and C_Item.GetItemInfoInstant then return C_Item.GetItemInfoInstant(item) end
    return GetItemInfoInstant(item)
end

--- C_QuestLog as the modules use it. The Classic Era client (1.15) lacks the quest log functions
--- of the newer ones (its log is read through GetQuestLogTitle): they are rebuilt here, in a table
--- of our own so the other addons, which test whether C_QuestLog has them, see the game as it is.
local function LogEntry(index)
    local title, level, _, isHeader, isCollapsed, isComplete, frequency, questID = GetQuestLogTitle(index)
    if not title then return nil end
    return {
        title = title,
        level = level,
        isHeader = isHeader and true or false,
        isCollapsed = isCollapsed and true or false,
        questID = questID or 0,
        frequency = frequency,
        state = isComplete, -- 1 complete, -1 failed
    }
end

local function LogIndex(questID)
    local index = GetQuestLogIndexByID and GetQuestLogIndexByID(questID)
    return index and index > 0 and index or nil
end

local function LogState(questID)
    local index = LogIndex(questID)
    local entry = index and LogEntry(index)
    return entry and entry.state
end

local classicLog = {
    GetNumQuestLogEntries = function() return (GetNumQuestLogEntries()) end,
    GetInfo = LogEntry,
    GetLogIndexForQuestID = LogIndex,
    GetTitleForQuestID = function(questID)
        if C_QuestLog.GetQuestInfo then return C_QuestLog.GetQuestInfo(questID) end
        local index = LogIndex(questID)
        return index and (GetQuestLogTitle(index))
    end,
    IsComplete = function(questID) return LogState(questID) == 1 end,
    IsFailed = function(questID) return LogState(questID) == -1 end,
    IsOnQuest = function(questID) return LogIndex(questID) ~= nil end,
    IsQuestFlaggedCompleted = IsQuestFlaggedCompleted,
    -- Classic Era and TBC have GetQuestsCompleted, a set { [questID] = true }: a sorted list here.
    GetAllCompletedQuestIDs = function()
        if not GetQuestsCompleted then return nil end
        local ids = {}
        for id, done in pairs(GetQuestsCompleted() or {}) do
            if done then table.insert(ids, id) end
        end
        table.sort(ids)
        return ids
    end,
}
FG.QuestLog = setmetatable({}, {
    __index = function(_, name) return C_QuestLog[name] or classicLog[name] end,
})

--- Parse a GUID into its entity type ("npc", "object", "player") and ID.
function FG.ParseGUID(guid)
    guid = FG.Readable(guid)
    if not guid then return nil end
    local kind, _, _, _, _, id = strsplit("-", guid)
    if kind == "Creature" or kind == "Vehicle" then
        return "npc", tonumber(id)
    elseif kind == "GameObject" then
        return "object", tonumber(id)
    elseif kind == "Player" then
        return "player", nil
    end
    return nil
end

--- Player position as uiMapID, x, y (percent, 2 decimals).
function FG.PlayerPosition()
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID then return nil end
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return mapID end
    local x, y = pos:GetXY()
    x, y = FG.Readable(x), FG.Readable(y)
    if not x then return mapID end
    return mapID, math.floor(x * 10000 + 0.5) / 100, math.floor(y * 10000 + 0.5) / 100
end

local characterKey -- once known, for the session

--- A character's key from its name, its realm's name and its GUID: "Name-Realm". Where the
--- game gives no realm name (WoW Forever), the realm is told by the GUID, "#<realm's number>-
--- <the character's own number>": on WoW Forever the characters of one account share their
--- name as the game gives it ("Weirdman" for "Weirdman Dan" and "Weirdman Blueback"), so the
--- character's own number is what tells them apart. Returns the key and its realm part ("" while
--- neither a realm name nor a GUID is known).
function FG.CharacterKeyOf(name, realm, guid)
    name = name or ""
    if not realm or realm == "" then
        local server, id = (type(guid) == "string" and guid or ""):match("^Player%-(%d+)%-(%x+)")
        realm = server and ("#" .. server .. "-" .. id) or ""
    end
    return name .. "-" .. realm, realm
end

--- What older versions kept for this character under a key several characters shared goes to
--- the character it was last used by (its class and race): "Name-#<realm>", which every
--- character of that name on the realm had, and "Name-" before that. The others start anew.
function FG.AdoptCharacter(db, key, name, realm, class, race, raceID)
    local chars = type(db) == "table" and type(db.characters) == "table" and db.characters
    if not chars or chars[key] or realm:sub(1, 1) ~= "#" then return nil end
    local server = realm:match("^#(%d+)")
    for _, old in ipairs({ name .. "-#" .. (server or ""), name .. "-" }) do
        local was = old ~= key and chars[old]
        if type(was) == "table" and was.class == class and (was.race == race or was.race == raceID) then
            chars[key], chars[old] = was, nil
            for _, kept in ipairs({ "profiles", "sent" }) do
                local t = db[kept]
                if type(t) == "table" and t[old] ~= nil and t[key] == nil then
                    t[key], t[old] = t[old], nil
                end
            end
            return old
        end
    end
    return nil
end

--- This character's key in the saved variables (FG.CharacterKeyOf), the same for a whole
--- session once its name and realm are known.
function FG:CharacterKey()
    if characterKey then return characterKey end
    local name = UnitName("player") or ""
    local realm = GetNormalizedRealmName and GetNormalizedRealmName() or nil
    if not realm or realm == "" then realm = GetRealmName and GetRealmName() or "" end
    local key, known = FG.CharacterKeyOf(name, realm, UnitGUID and FG.Readable(UnitGUID("player")))
    if name == "" or known == "" then return key end
    characterKey = key
    local _, classFile = UnitClass("player")
    local _, raceFile, raceID = UnitRace("player")
    FG.AdoptCharacter(PathwrightDB, key, name, known, classFile, raceFile, raceID)
    return key
end

-- Skill names in the skills list, for clients without GetProfessions (matched by name).
local SKILL_NAMES = {
    [171] = { "Alchemy", "Alchimie" },
    [164] = { "Blacksmithing", "Forge" },
    [333] = { "Enchanting", "Enchantement" },
    [202] = { "Engineering", "Ingénierie" },
    [182] = { "Herbalism", "Herboristerie" },
    [165] = { "Leatherworking", "Travail du cuir" },
    [186] = { "Mining", "Minage" },
    [393] = { "Skinning", "Dépeçage" },
    [197] = { "Tailoring", "Couture" },
    [185] = { "Cooking", "Cuisine" },
    [356] = { "Fishing", "Pêche" },
    [129] = { "First Aid", "Secourisme" },
    [762] = { "Riding", "Monte" },
}

--- Skill of a profession by skill line ID: rank, max rank, localized name (nil if unknown).
function FG.ProfessionSkill(line)
    if GetProfessions and GetProfessionInfo then
        for _, index in pairs({ GetProfessions() }) do
            local name, _, rank, maxRank, _, _, skillLine = GetProfessionInfo(index)
            if skillLine == line then return rank, maxRank, name end
        end
    end
    if GetNumSkillLines and GetSkillLineInfo then
        local names = SKILL_NAMES[line] or {}
        for i = 1, GetNumSkillLines() do
            local name, header, _, rank, _, _, maxRank = GetSkillLineInfo(i)
            if not header and (name == names[1] or name == names[2]) then return rank, maxRank, name end
        end
    end
    return nil
end

-- The reputation panel's rows (Forever: C_Reputation; Classic Era and TBC: the older globals):
-- faction ID, points, header, collapsed, header with points of its own, name.
local function ReputationAPI()
    if C_Reputation and C_Reputation.GetFactionDataByIndex and C_Reputation.GetNumFactions then
        return C_Reputation.GetNumFactions,
            function(i)
                local d = C_Reputation.GetFactionDataByIndex(i)
                if d then
                    return d.factionID, d.currentStanding, d.isHeader, d.isCollapsed, d.isHeaderWithRep, d.name
                end
            end,
            C_Reputation.ExpandFactionHeader,
            C_Reputation.CollapseFactionHeader
    end
    if GetNumFactions and GetFactionInfo then
        return GetNumFactions,
            function(i)
                local name, _, _, _, _, value, _, _, header, collapsed, hasRep, _, _, id = GetFactionInfo(i)
                return id, value, header, collapsed, hasRep, name
            end,
            ExpandFactionHeader,
            CollapseFactionHeader
    end
end

--- Points with every faction the reputation panel lists, counted from the bottom of Neutral:
--- { { id = factionID, value = points }... } (and `name`, in the game's language, with `withNames`).
--- Collapsed headers hide their factions: opened for the reading and closed again, unless the
--- panel is open (the player is using it).
function FG.Reputations(withNames)
    local count, row, expand, collapse = ReputationAPI()
    if not count then return {} end
    local panel = ReputationFrame and ReputationFrame:IsVisible()
    local opened, out = {}, {}
    local i = 1
    while i <= count() do
        local id, value, header, collapsed, hasRep, name = row(i)
        if header and collapsed and expand and not panel then
            expand(i)
            opened[id or name or i] = true
        end
        value = FG.Readable(value)
        if id and value and (not header or hasRep) then
            table.insert(out, { id = id, value = value, name = withNames and name or nil })
        end
        i = i + 1
    end
    if collapse then
        -- From the last row: closing a header leaves the rows before it where they are.
        for k = count(), 1, -1 do
            local id, _, header, _, _, name = row(k)
            if header and opened[id or name or k] then collapse(k) end
        end
    end
    return out
end

FG:On("ADDON_LOADED", function(name)
    if name ~= addonName then return end
    PathwrightDB = PathwrightDB or {}
    PathwrightDB.version = FG.DB_VERSION
    PathwrightDB.characters = PathwrightDB.characters or {}
    -- For the app: the game loaded the addon, when, and which app version installed it (its .toc).
    local metadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
    PathwrightDB.seen = { time = time(), version = metadata and metadata(addonName, "Version") or "?" }
end)

-- The only chat command: `/pw` (or `/pathwright`), with anything after it, opens the addon's
-- pages in the game's options (Options.lua). Everything else is done there, with the guide's
-- buttons or with key bindings.
SLASH_PATHWRIGHT1 = "/pw"
SLASH_PATHWRIGHT2 = "/pathwright"
SlashCmdList.PATHWRIGHT = function(msg)
    -- "/pw guides": the guide browser (the guide part, when loaded).
    if type(msg) == "string" and msg:lower():match("^%s*guides") and FG.GuideBrowser then
        return FG.GuideBrowser:Toggle()
    end
    -- "/pw board": the quest stats leaderboard (the guide part).
    if type(msg) == "string" and msg:lower():match("^%s*board") and FG.Stats then return FG.Stats:ToggleBoard() end
    -- "/pw way": what the way from here is doing (the guide part: Pathing.lua).
    if type(msg) == "string" and msg:lower():match("^%s*way") and FG.Pathing and FG.Pathing.Say then
        return FG.Pathing:Say()
    end
    -- "/pw party": who in the party runs the addon, and whether quests are shared (Party.lua).
    if type(msg) == "string" and msg:lower():match("^%s*party") and FG.Party and FG.Party.Say then
        return FG.Party:Say()
    end
    -- "/pw feedback": tell us what went wrong (the guide part).
    if type(msg) == "string" and msg:lower():match("^%s*feedback") and FG.Feedback then return FG.Feedback:Toggle() end
    FG.Options:Open()
end
