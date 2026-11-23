-- Pick a guide from the same sections and filters as the settings page, then open it in a tab.

local FG = Pathwright
local T = FG.T
local Skin = FG.Skin
local Browser = { offset = 0 }
FG.GuideBrowser = Browser

local L = {
    title = T("Guides"),
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
    none = T("No matching guides"),
    pick = T("Pick a guide in the list"),
    shown = T("%d-%d of %d"),
}

local WIDTH, HEIGHT = 700, 492
local LIST_W = 385
local ROW_H, ROWS = 34, 10
local DETAIL_ROWS = 6
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
    r:SetScript("OnLeave", function(self)
        if self.guide and self.guide.name ~= Browser.picked then Paint(self.bg, "bg", 0) end
    end)
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

    frame.filters = FG.Options.GuideFilters(frame, "PathwrightBrowserGuideFilters", function()
        Browser.offset, Browser.picked = 0, nil
        Browser:Fill()
    end)
    frame.filters:SetPoint("TOPLEFT", 14, -38)
    frame.filters:SetPoint("TOPRIGHT", -14, -38)

    -- The list.
    frame.list = CreateFrame("Frame", nil, frame)
    frame.list:SetPoint("TOPLEFT", 12, -100)
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
    frame.shown:SetPoint("TOP", frame.list, "BOTTOM", 0, -8)
    frame.prevPage = FG.Options.Button(frame, T("Previous"), 76, function()
        Browser.offset = math.max(0, Browser.offset - ROWS)
        Browser:Fill()
    end)
    frame.prevPage:SetPoint("TOPLEFT", frame.list, "BOTTOMLEFT", 0, -4)
    frame.nextPage = FG.Options.Button(frame, T("Next"), 76, function()
        Browser.offset = math.min(Browser.maxOffset, Browser.offset + ROWS)
        Browser:Fill()
    end)
    frame.nextPage:SetPoint("TOPRIGHT", frame.list, "BOTTOMRIGHT", 0, -4)

    -- The guide picked.
    -- Its name, what the character does with it, then a label over each value, one under the
    -- other: a value that wraps pushes the next ones down.
    local x = LIST_W + 28
    local width = WIDTH - x - 16
    frame.dName = Skin:Text(frame, 15, "text")
    frame.dName:SetPoint("TOPLEFT", x, -100)
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

    Skin:Style(frame, "window", { frame.title, frame.empty, frame.shown, frame.dName, frame.dStatus })
    frame:SetScale(FG:Get("scale") or 1)
    if UISpecialFrames then table.insert(UISpecialFrames, "PathwrightGuideBrowser") end
    frame:Hide()
end

--- Draw the window from the guides of the moment.
function Browser:Fill()
    if not frame or not frame:IsShown() then return end
    local guides = frame.filters:Results()
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
            r.name:SetText(FG.Options.GuideTitle(g))
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
    frame.prevPage:SetShown(#guides > ROWS)
    frame.nextPage:SetShown(#guides > ROWS)
    frame.prevPage:SetEnabled(self.offset > 0)
    frame.nextPage:SetEnabled(self.offset < self.maxOffset)
    frame.shown:SetText(
        #guides > ROWS and string.format(L.shown, self.offset + 1, math.min(#guides, self.offset + ROWS), #guides) or ""
    )
    -- The guide picked may be scrolled away: still shown.
    if not picked and self.picked then
        for _, g in ipairs(guides) do
            if g.name == self.picked then picked = g end
        end
    end
    self.picked = picked and picked.name
    self:Details(picked, open, current)
end

--- Who a guide is for: the character, or the race and class it was made for.
local function ForWhom(g)
    local who = FG.Options.RaceClass and FG.Options.RaceClass(g.route) or ""
    if g.fits then return who end
    return who .. "\n" .. Skin.Hex("orange") .. L.forOther .. "|r"
end

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
        { L.lSource, FG.Options.GuideSectionName(g) },
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

--- Open the window or close it, retaining the section and its filters.
function Browser:Toggle()
    if not frame then Create() end
    if frame:IsShown() then return frame:Hide() end
    self.picked = FG.Guide:RouteName()
    self.offset = 0
    frame:Show()
    self:Fill()
end

function Browser:IsShown() return frame and frame:IsShown() or false end

-- The window follows the guides: refreshed when they change while it is open.
FG:On("PLAYER_LEVEL_UP", function() Browser:Fill() end)
