-- The guide browser, as Zygor has one: a window to look through the guides there are and open one
-- in a tab. Opened by the tabs' "+" (Tabs.lua) or `/pw guides`.
--
--   left    the sources: suggested for the character, built into the addon, imported, from the
--           app, all of them; with how many each holds
--   middle  their guides, by level (a badge framed and written in the color of how the levels
--           compare with the character's: grey done, green easy, yellow right, orange hard, red
--           too hard), searched
--           by name; the guides open in a tab marked
--   right   the guide picked: who it is for, its levels, steps and quests, the guide after it,
--           where the character is in it; "Open" (in a tab, followed), "Close the tab"
--
-- A guide is suggested when it is made for the character (Import.Fits) and its levels are about
-- the character's, or it follows the guide being followed.

local FG = Pathwright
local T = FG.T
local Skin = FG.Skin
local Browser = { source = "suggested", offset = 0 }
FG.GuideBrowser = Browser

local L = {
    title = T("Guides"),
    search = T("Search"),
    suggested = T("Suggested for you"),
    builtin = T("Guides"),
    imported = T("Imported"),
    app = T("From the app"),
    all = T("All guides"),
    mine = T("Only guides for this character"),
    open = T("Open"),
    switch = T("Follow it"),
    closeTab = T("Close the tab"),
    following = T("You follow this guide"),
    inTab = T("Open in a tab"),
    forOther = T("Made for another race or class"),
    steps = T("%d steps, %d quests"),
    progress = T("Step %d of %d"),
    lLevels = T("Levels"),
    lFor = T("For"),
    lLength = T("Length"),
    lProgress = T("Progress"),
    lNext = T("Next guide"),
    lSource = T("Source"),
    notStarted = T("Not started"),
    none = T("No guide here"),
    pick = T("Pick a guide in the list"),
    shown = T("%d-%d of %d"),
}

local WIDTH, HEIGHT = 700, 450
local LEFT_W, LIST_W = 160, 290
local ROW_H, ROWS = 34, 10
local DETAIL_ROWS = 6
local SOURCES = {
    { key = "suggested", label = L.suggested },
    { key = "builtin", label = L.builtin },
    { key = "import", label = L.imported },
    { key = "app", label = L.app },
    { key = "all", label = L.all },
}

local frame

local function Color(name)
    local c = Skin.colors[name]
    return c[1], c[2], c[3]
end

local function Paint(texture, color, alpha)
    local r, g, b = Color(color)
    texture:SetColorTexture(r, g, b, alpha or 1)
end

--- The color of a guide's levels against the character's, as the game colors quests.
local function LevelColor(from, to)
    local level = tonumber(FG.Readable(UnitLevel("player"))) or 1
    if not from then return "muted" end
    to = to or from
    if level > to + 3 then return "muted" end
    if level > to then return "green" end
    if level >= from - 2 then return "gold" end
    if level >= from - 4 then return "orange" end
    return "red"
end

--- Quests a route has (each counted once).
local function QuestCount(r)
    local seen, n = {}, 0
    for _, s in ipairs(r.steps or {}) do
        if s.q and not seen[s.q] then
            seen[s.q], n = true, n + 1
        end
    end
    return n
end

--- Whether a guide is suggested to the character.
local function Suggested(g)
    local r = g.route
    local current = FG.Guide:RouteName()
    local currentRoute = current and FG.Routes[current]
    if currentRoute and currentRoute.next == g.name then return true end
    if not g.fits then return false end
    local level = tonumber(FG.Readable(UnitLevel("player"))) or 1
    return (r.fromLevel or 1) - 2 <= level and level <= (r.toLevel or 60) + 1
end

--- The guides of a source (and the search), by level then name.
local function Guides(source, search, mineOnly)
    local out = {}
    search = search and search ~= "" and search:lower() or nil
    for _, g in ipairs(FG.Import:List()) do
        local keep = source == "all" or g.source == source or (source == "suggested" and Suggested(g))
        if keep and mineOnly and source ~= "suggested" and not g.fits then keep = false end
        if keep and search and not g.name:lower():find(search, 1, true) then keep = false end
        if keep then out[#out + 1] = g end
    end
    table.sort(out, function(a, b)
        local la, lb = a.route.fromLevel or 0, b.route.fromLevel or 0
        if la ~= lb then return la < lb end
        return a.name < b.name
    end)
    return out
end

-- The window ---------------------------------------------------------------------------------------

local function SourceButton(i)
    local b = CreateFrame("Button", nil, frame)
    b:SetSize(LEFT_W - 16, 24)
    b:SetPoint("TOPLEFT", 10, -46 - (i - 1) * 26)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.label = Skin:Text(b, 11, "text2")
    b.label:SetPoint("LEFT", 8, 0)
    b.count = Skin:Text(b, 10, "muted")
    b.count:SetPoint("RIGHT", -8, 0)
    b:SetScript("OnClick", function(self)
        Browser.source, Browser.offset, Browser.picked = self.key, 0, nil
        Browser:Fill()
    end)
    return b
end

local function Row(i)
    local r = CreateFrame("Button", nil, frame.list)
    r:SetSize(LIST_W - 12, ROW_H - 2)
    r:SetPoint("TOPLEFT", 6, -6 - (i - 1) * ROW_H)
    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints()
    -- The levels: in the difficulty's color, on a dark box framed in it (readable on any theme).
    r.badge = r:CreateTexture(nil, "BORDER")
    r.badge:SetSize(50, ROW_H - 10)
    r.badge:SetPoint("LEFT", 4, 0)
    r.badgeInner = r:CreateTexture(nil, "ARTWORK")
    r.badgeInner:SetPoint("TOPLEFT", r.badge, "TOPLEFT", 2, -2)
    r.badgeInner:SetPoint("BOTTOMRIGHT", r.badge, "BOTTOMRIGHT", -2, 2)
    r.badgeInner:SetColorTexture(0.04, 0.05, 0.08, 1)
    r.levels = r:CreateFontString(nil, "OVERLAY")
    r.levels:SetFontObject(Skin.FontObject(12, "OUTLINE", false))
    r.levels:SetPoint("CENTER", r.badge, "CENTER", 0, 0)
    r.name = Skin:Text(r, 11, "text")
    r.name:SetPoint("TOPLEFT", r.badge, "TOPRIGHT", 8, 1)
    r.name:SetPoint("RIGHT", -8, 0)
    r.name:SetWordWrap(false)
    r.sub = Skin:Text(r, 9, "muted")
    r.sub:SetPoint("BOTTOMLEFT", r.badge, "BOTTOMRIGHT", 8, -1)
    r.sub:SetPoint("RIGHT", -8, 0)
    r.sub:SetWordWrap(false)
    r:SetScript("OnClick", function(self)
        Browser.picked = self.guide and self.guide.name
        Browser:Fill()
    end)
    r:SetScript("OnDoubleClick", function(self)
        if self.guide then Browser:Open(self.guide.name) end
    end)
    r:SetScript("OnEnter", function(self)
        if self.guide and self.guide.name ~= Browser.picked then Paint(self.bg, "accent", 0.08) end
    end)
    r:SetScript("OnLeave", function() Browser:Fill() end)
    return r
end

local function Create()
    frame = CreateFrame("Frame", "PathwrightGuideBrowser", FG.UIRoot, "BackdropTemplate")
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    FG:Draggable(frame)
    frame.title = Skin:Text(frame, 15, "text")
    frame.title:SetPoint("TOPLEFT", 14, -12)
    frame.title:SetText(L.title)
    frame.close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    frame.close:SetPoint("TOPRIGHT", -2, -2)

    -- Search, at the top of the list.
    frame.search = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    frame.search:SetSize(LIST_W - 70, 20)
    frame.search:SetPoint("TOPLEFT", LEFT_W + 60, -12)
    frame.search:SetAutoFocus(false)
    frame.search:SetScript("OnTextChanged", function()
        Browser.offset = 0
        Browser:Fill()
    end)
    frame.search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    frame.searchLabel = Skin:Text(frame, 10, "muted")
    frame.searchLabel:SetPoint("RIGHT", frame.search, "LEFT", -10, 0)
    frame.searchLabel:SetText(L.search)

    -- The sources.
    frame.sources = {}
    for i, s in ipairs(SOURCES) do
        local b = SourceButton(i)
        b.key = s.key
        b.label:SetText(s.label)
        frame.sources[i] = b
    end
    frame.mine = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    frame.mine:SetSize(22, 22)
    frame.mine:SetPoint("TOPLEFT", 8, -46 - #SOURCES * 26 - 10)
    frame.mine:SetChecked(true)
    frame.mine:SetScript("OnClick", function()
        Browser.offset = 0
        Browser:Fill()
    end)
    frame.mineLabel = Skin:Text(frame, 10, "text2")
    frame.mineLabel:SetPoint("TOPLEFT", frame.mine, "TOPRIGHT", 2, -4)
    frame.mineLabel:SetWidth(LEFT_W - 40)
    frame.mineLabel:SetJustifyH("LEFT")
    frame.mineLabel:SetText(L.mine)

    -- The list.
    frame.list = CreateFrame("Frame", nil, frame)
    frame.list:SetPoint("TOPLEFT", LEFT_W, -42)
    frame.list:SetSize(LIST_W, ROWS * ROW_H + 12)
    frame.list.bg = frame.list:CreateTexture(nil, "BACKGROUND")
    frame.list.bg:SetAllPoints()
    Paint(frame.list.bg, "line", 0.35)
    frame.list:EnableMouseWheel(true)
    frame.list:SetScript("OnMouseWheel", function(_, delta)
        Browser.offset = math.max(0, math.min(Browser.maxOffset or 0, Browser.offset - delta))
        Browser:Fill()
    end)
    frame.rows = {}
    for i = 1, ROWS do
        frame.rows[i] = Row(i)
    end
    frame.empty = Skin:Text(frame.list, 11, "muted")
    frame.empty:SetPoint("CENTER")
    frame.empty:SetText(L.none)
    frame.shown = Skin:Text(frame, 9, "muted")
    frame.shown:SetPoint("TOPRIGHT", frame.list, "BOTTOMRIGHT", -4, -6)

    -- The guide picked.
    -- Its name, what the character does with it, then a label over each value, one under the
    -- other: a value that wraps pushes the next ones down.
    local x = LEFT_W + LIST_W + 18
    local width = WIDTH - x - 16
    frame.dName = Skin:Text(frame, 15, "text")
    frame.dName:SetPoint("TOPLEFT", x, -46)
    frame.dName:SetWidth(width)
    frame.dName:SetJustifyH("LEFT")
    frame.dName:SetWordWrap(true)
    frame.dStatus = Skin:Text(frame, 10, "accent")
    frame.dStatus:SetPoint("TOPLEFT", frame.dName, "BOTTOMLEFT", 0, -4)
    frame.dStatus:SetWidth(width)
    frame.dStatus:SetJustifyH("LEFT")
    frame.dRule = Skin:Fill(frame, "ARTWORK", "line", 1)
    frame.dRule:SetHeight(1)
    frame.dRule:SetPoint("TOPLEFT", frame.dStatus, "BOTTOMLEFT", 0, -10)
    frame.dRule:SetWidth(width)
    local rows, above = {}, frame.dRule
    for i = 1, DETAIL_ROWS do
        local label = Skin:Text(frame, 9, "muted")
        label:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, i == 1 and -10 or -12)
        label:SetWidth(width)
        label:SetJustifyH("LEFT")
        local value = Skin:Text(frame, 12, "text2")
        value:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -3)
        value:SetWidth(width)
        value:SetJustifyH("LEFT")
        value:SetWordWrap(true)
        rows[i] = { label = label, value = value }
        above = value
    end
    frame.dRows = rows
    frame.openButton = FG.Options.Button(frame, L.open, 110, function()
        if Browser.picked then Browser:Open(Browser.picked) end
    end)
    frame.openButton:SetPoint("BOTTOMLEFT", x, 16)
    frame.closeTab = FG.Options.Button(frame, L.closeTab, 110, function()
        if Browser.picked then
            FG.Guide:CloseTab(Browser.picked)
            Browser:Fill()
        end
    end)
    frame.closeTab:SetPoint("LEFT", frame.openButton, "RIGHT", 8, 0)

    Skin:Style(
        frame,
        "window",
        { frame.title, frame.searchLabel, frame.mineLabel, frame.empty, frame.shown, frame.dName, frame.dStatus }
    )
    frame:SetScale(FG:Get("scale") or 1)
    if UISpecialFrames then table.insert(UISpecialFrames, "PathwrightGuideBrowser") end
    frame:Hide()
end

--- Draw the window from the guides of the moment.
function Browser:Fill()
    if not frame or not frame:IsShown() then return end
    local mineOnly = frame.mine:GetChecked() == true
    local search = frame.search:GetText()
    if type(search) ~= "string" then search = "" end
    for _, b in ipairs(frame.sources) do
        local n = #Guides(b.key, search, mineOnly)
        b.count:SetText(n > 0 and tostring(n) or "")
        local on = b.key == self.source
        Paint(b.bg, on and "accent" or "bg", on and 0.25 or 0)
        b.label:SetTextColor(Color(on and "text" or "text2"))
    end
    local guides = Guides(self.source, search, mineOnly)
    self.maxOffset = math.max(0, #guides - ROWS)
    self.offset = math.min(self.offset, self.maxOffset)
    local open = {}
    for _, name in ipairs(FG.Guide:Tabs()) do
        open[name] = true
    end
    local current = FG.Guide:RouteName()
    local picked
    for i, r in ipairs(frame.rows) do
        local g = guides[self.offset + i]
        r.guide = g
        if g then
            local route = g.route
            r.levels:SetText(string.format("%d-%d", route.fromLevel or 0, route.toLevel or 0))
            local color = LevelColor(route.fromLevel, route.toLevel)
            -- The world's colors: light inks that read on the dark box whatever the theme.
            local c = Skin:World().colors[color] or Skin.colors[color]
            r.badge:SetColorTexture(c[1], c[2], c[3], 1)
            r.levels:SetTextColor(c[1], c[2], c[3])
            r.name:SetText(g.name)
            r.name:SetTextColor(Color(g.fits and "text" or "muted"))
            local status = g.name == current and L.following or open[g.name] and L.inTab or ""
            local who = g.fits and "" or L.forOther
            r.sub:SetText(status ~= "" and who ~= "" and (status .. "  •  " .. who) or (status .. who))
            if g.name == self.picked then
                Paint(r.bg, "accent", 0.2)
                picked = g
            else
                Paint(r.bg, "bg", 0)
            end
            r:Show()
        else
            r:Hide()
        end
    end
    frame.empty:SetShown(#guides == 0)
    frame.shown:SetText(
        #guides > ROWS and string.format(L.shown, self.offset + 1, math.min(#guides, self.offset + ROWS), #guides) or ""
    )
    -- The guide picked may be scrolled away: still shown.
    if not picked and self.picked then
        for _, g in ipairs(FG.Import:List()) do
            if g.name == self.picked then picked = g end
        end
    end
    self:Details(picked, open, current)
end

--- Who a guide is for: the character, or the race and class it was made for.
local function ForWhom(g)
    local who = FG.Options.RaceClass and FG.Options.RaceClass(g.route) or ""
    if g.fits then return who end
    return who .. "\n" .. Skin.Hex("orange") .. L.forOther .. "|r"
end

local SOURCE_NAMES = { builtin = L.builtin, import = L.imported, app = L.app }

function Browser:Details(g, open, current)
    local rows = frame.dRows
    for _, row in ipairs(rows) do
        row.label:SetText("")
        row.value:SetText("")
    end
    frame.dStatus:SetText("")
    if not g then
        frame.dName:SetText(L.pick)
        frame.dName:SetTextColor(Color("muted"))
        frame.dRule:Hide()
        frame.openButton:Hide()
        frame.closeTab:Hide()
        return
    end
    local r = g.route
    frame.dName:SetText(g.name)
    frame.dName:SetTextColor(Color("text"))
    frame.dStatus:SetText(g.name == current and L.following or open[g.name] and L.inTab or "")
    frame.dRule:Show()
    local step, total = FG.Guide:Progress(g.name)
    local color = Skin.Hex(LevelColor(r.fromLevel, r.toLevel))
    local list = {
        { L.lLevels, color .. string.format("%d-%d", r.fromLevel or 0, r.toLevel or 0) .. "|r" },
        { L.lFor, ForWhom(g) },
        { L.lLength, string.format(L.steps, #(r.steps or {}), QuestCount(r)) },
        { L.lProgress, step and string.format(L.progress, math.min(step, total), total) or L.notStarted },
        r.next and { L.lNext, r.next } or false,
        { L.lSource, SOURCE_NAMES[g.source] or "" },
    }
    local n = 0
    for _, item in ipairs(list) do
        if item then
            n = n + 1
            rows[n].label:SetText(item[1]:upper())
            rows[n].value:SetText(item[2])
        end
    end
    frame.openButton:SetText(open[g.name] and L.switch or L.open)
    frame.openButton:SetShown(g.name ~= current)
    frame.closeTab:SetShown(open[g.name] and true or false)
end

--- Open the guide `name` in a tab and follow it.
function Browser:Open(name)
    FG.Guide:Choose(name)
    if frame then frame:Hide() end
end

--- Open the window (the suggested guides first, the guide followed picked), or close it.
function Browser:Toggle()
    if not frame then Create() end
    if frame:IsShown() then return frame:Hide() end
    self.picked = FG.Guide:RouteName()
    self.offset = 0
    -- Nothing suggested: all the guides.
    self.source = "suggested"
    frame:Show()
    if #Guides("suggested", "", true) == 0 then self.source = "all" end
    self:Fill()
end

function Browser:IsShown() return frame and frame:IsShown() or false end

-- The window follows the guides: refreshed when they change while it is open.
FG:On("PLAYER_LEVEL_UP", function() Browser:Fill() end)
