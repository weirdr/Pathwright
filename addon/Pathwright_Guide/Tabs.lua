-- Guide tabs, as Zygor has them: the guides the character has open, along the bottom of the full
-- guide (over the minimal strip, whose next steps hang below it). A click follows a tab's guide,
-- each one where it was left (progress is kept per guide); a right click closes it. The "+" tab
-- opens the guide browser (GuideBrowser.lua) to pick a guide to open.

local FG = Pathwright
local T = FG.T
local Skin = FG.Skin
local Tabs = {}
FG.Tabs = Tabs

local L = {
    open = T("Open a guide"),
    close = T("Right-click: close the tab"),
    follow = T("Click: follow this guide"),
    board = T("Leaderboard: your quest scores with your friends"),
}

local HEIGHT, MAX_W, PLUS_W, GAP = 18, 118, 22, 2
local CARD_GAP = 1
Tabs.belowCard = CARD_GAP + HEIGHT

local bar

local function Paint(texture, color, alpha)
    local c = Skin.colors[color]
    texture:SetColorTexture(c[1], c[2], c[3], alpha or 1)
end

local function Tooltip(owner, lines)
    GameTooltip:SetOwner(owner, "ANCHOR_TOP")
    for i, line in ipairs(lines) do
        if i == 1 then
            GameTooltip:AddLine(line, 1, 1, 1, true)
        else
            GameTooltip:AddLine(line, 0.7, 0.7, 0.7, true)
        end
    end
    GameTooltip:Show()
end

--- A guide's entry of the list (Import:List), nil when it is gone.
local function Entry(name)
    for _, g in ipairs(FG.Import:List()) do
        if g.name == name then return g end
    end
end

-- The bar -----------------------------------------------------------------------------------------

local function Tab(i)
    local b = bar.tabs[i]
    if b then return b end
    b = CreateFrame("Button", nil, bar)
    b:SetHeight(HEIGHT)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.edge = b:CreateTexture(nil, "BORDER")
    b.edge:SetPoint("TOPLEFT")
    b.edge:SetPoint("TOPRIGHT")
    b.edge:SetHeight(1)
    b.mark = b:CreateTexture(nil, "ARTWORK")
    b.mark:SetPoint("BOTTOMLEFT")
    b.mark:SetPoint("BOTTOMRIGHT")
    b.mark:SetHeight(2)
    b.label = Skin:Text(b, 10, "text2")
    b.label:SetPoint("LEFT", 6, 0)
    b.label:SetPoint("RIGHT", -6, 0)
    b.label:SetWordWrap(false)
    b:SetScript("OnClick", function(self, button)
        if not self.name then return end
        if button == "RightButton" then
            FG.Guide:CloseTab(self.name)
        elseif self.name ~= FG.Guide:RouteName() then
            FG.Guide:Choose(self.name)
        end
    end)
    b:SetScript("OnEnter", function(self)
        local g = self.name and Entry(self.name)
        if not g then return end
        local details = FG.Options.GuideDetails and FG.Options.GuideDetails(g) or ""
        local lines = { self.name, details }
        if self.name ~= FG.Guide:RouteName() then lines[#lines + 1] = L.follow end
        lines[#lines + 1] = L.close
        Tooltip(self, lines)
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    bar.tabs[i] = b
    return b
end

local function CreateBar()
    bar = CreateFrame("Frame", "PathwrightTabs", FG.UIRoot)
    bar:SetHeight(HEIGHT)
    bar.tabs = {}
    bar.plus = CreateFrame("Button", nil, bar)
    bar.plus:SetSize(PLUS_W, HEIGHT)
    bar.plus.bg = bar.plus:CreateTexture(nil, "BACKGROUND")
    bar.plus.bg:SetAllPoints()
    bar.plus.label = Skin:Text(bar.plus, 14, "accent")
    bar.plus.label:SetPoint("CENTER", 0, 1)
    bar.plus.label:SetText("+")
    bar.plus:SetScript("OnClick", function() FG.GuideBrowser:Toggle() end)
    bar.plus:SetScript("OnEnter", function(self) Tooltip(self, { L.open }) end)
    bar.plus:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- At the right end, a crown: the leaderboard of quest scores with your friends (Stats.lua).
    bar.board = CreateFrame("Button", nil, bar)
    bar.board:SetSize(PLUS_W, HEIGHT)
    bar.board:SetPoint("TOPRIGHT")
    bar.board.bg = bar.board:CreateTexture(nil, "BACKGROUND")
    bar.board.bg:SetAllPoints()
    bar.board.icon = bar.board:CreateTexture(nil, "ARTWORK")
    bar.board.icon:SetSize(12, 12)
    bar.board.icon:SetPoint("CENTER")
    bar.board.icon:SetTexture("Interface\\GroupFrame\\UI-Group-LeaderIcon")
    bar.board:SetScript("OnClick", function()
        if FG.Stats then FG.Stats:ToggleBoard() end
    end)
    bar.board:SetScript("OnEnter", function(self) Tooltip(self, { L.board }) end)
    bar.board:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

--- Draw the tabs at the guide's look of the moment (`ui`: FG.Card or FG.Mini).
function Tabs:Render(ui)
    local host = ui and ui.Frame and ui:Frame()
    if not host then return end
    if not bar then CreateBar() end
    local minimal = ui == FG.Mini
    if bar:GetParent() ~= host or bar.minimal ~= minimal then
        bar:SetParent(host)
        bar:ClearAllPoints()
        if minimal then
            bar:SetPoint("BOTTOMLEFT", host, "TOPLEFT", 0, 1)
        else
            bar:SetPoint("TOPLEFT", host, "BOTTOMLEFT", 0, -CARD_GAP)
        end
        bar.minimal = minimal
    end
    local width = tonumber(host:GetWidth()) or 300
    bar:SetWidth(width)
    bar:Show()
    Paint(bar.board.bg, "bg", 0.75)

    local names = FG.Guide:Tabs()
    local current = FG.Guide:RouteName()
    -- Each tab as wide as its name (up to MAX_W), all shrunk alike when they do not fit.
    local wanted, total = {}, 0
    for i, name in ipairs(names) do
        local b = Tab(i)
        b.label:SetText(name)
        wanted[i] = math.min(MAX_W, (tonumber(b.label:GetStringWidth()) or 60) + 14)
        total = total + wanted[i] + GAP
    end
    local room = width - 2 * PLUS_W - GAP
    local factor = total > room and room / total or 1
    local x = 0
    for i, name in ipairs(names) do
        local b = bar.tabs[i]
        local active = name == current
        b.name = name
        local w = math.max(24, math.floor(wanted[i] * factor))
        b:SetWidth(w)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", x, 0)
        x = x + w + GAP
        Paint(b.bg, "bg", active and 0.95 or 0.75)
        Paint(b.edge, "edge", 1)
        Paint(b.mark, "accent", 1)
        b.mark:SetShown(active)
        local c = Skin.colors[active and "text" or "muted"]
        b.label:SetTextColor(c[1], c[2], c[3])
        b:Show()
    end
    for i = #names + 1, #bar.tabs do
        bar.tabs[i]:Hide()
        bar.tabs[i].name = nil
    end
    bar.plus:ClearAllPoints()
    bar.plus:SetPoint("TOPLEFT", x, 0)
    Paint(bar.plus.bg, "bg", FG.GuideBrowser:IsShown() and 0.95 or 0.75)
    -- The browser shows the guides of the moment (a tab opened or closed).
    FG.GuideBrowser:Fill()
end
