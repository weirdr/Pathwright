-- The addon's pages in the game's options (Options, AddOns, Pathwright), opened by `/pw` (or
-- `/factoruide`) and by the guide's options button. The main page: the character (export it, save
-- its profile) and the blocks the guide part adds (the guides in use). Under it, the pages the
-- guide part adds (a page per group of settings) and the Advanced page (the recordings). Each part
-- adds its own while it loads (Options:AddBlock, Options:AddPage, Options:AddButton); everything is
-- built and registered at login, at once. What is done while playing (next step, the guide's
-- mode...) is not here: the guide's buttons and the key bindings (Pathwright_Guide/Bindings.xml).

local _, FG = ...
local T = FG.T
local Options = { blocks = {}, pages = {}, buttons = {} }
FG.Options = Options

local PAD, GAP = 16, 20
local panel, content
local blocks = {} -- the main page's blocks, in their order

--- Add a block to the main page: `create(parent)` returns its frame, its height set; its
--- `Refresh(availableHeight)` (optional) receives the remaining height once the panel is sized.
function Options:AddBlock(create) table.insert(self.blocks, create) end

--- Add pages under the addon's: `build(category)` registers its subcategories.
function Options:AddPage(build) table.insert(self.pages, build) end

--- A button under setting `after` on its page: { label, text (on the button), help, run }.
function Options:AddButton(after, button)
    self.buttons[after] = self.buttons[after] or {}
    table.insert(self.buttons[after], button)
end

--- A button row of a page (vertical layout): its label, then the button.
function Options.ButtonInitializer(button)
    local help = button.help and T(button.help) or nil
    return CreateSettingsButtonInitializer(T(button.label), T(button.text), function() button.run() end, help, true)
end

--- `frame` shows `title` and `help` in the game's tooltip.
function Options.Tooltip(frame, title, help)
    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(title, 1, 1, 1, 1, true)
        if help then GameTooltip:AddLine(help, nil, nil, nil, true) end
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

--- One of the game's panel buttons, at least `width` wide (its text decides otherwise).
function Options.Button(parent, text, width, onClick, help)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetText(text)
    b:SetSize(math.max(width or 0, (tonumber(b:GetTextWidth()) or 0) + 24), 22)
    b:SetScript("OnClick", onClick)
    if help then Options.Tooltip(b, text, help) end
    return b
end

--- A section's title on the main page, as the game's pages write theirs.
function Options.Heading(parent, text)
    local heading = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
    heading:SetJustifyH("LEFT")
    heading:SetText(text)
    return heading
end

-- The character: its export for the web app, its profile saved at once.
Options:AddBlock(function(parent)
    local block = CreateFrame("Frame", nil, parent)
    block:SetHeight(56)
    local heading = Options.Heading(block, T("Character"))
    heading:SetPoint("TOPLEFT", 0, 0)
    local export = Options.Button(
        block,
        T("Export my character"),
        180,
        function() FG.Profile:Export() end,
        T("Your character as a text to paste in the Pathwright web app.")
    )
    export:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -10)
    local save = Options.Button(
        block,
        T("Save the profile now"),
        180,
        function() FG.Profile:Save() end,
        T("Saves your character for the Pathwright app now: the interface reloads.")
    )
    save:SetPoint("LEFT", export, "RIGHT", 8, 0)
    return block
end)

--- Lay the main page's blocks out again (guides added, deleted, followed...).
function Options:Refresh()
    if not content then return end
    local height = tonumber(content:GetHeight())
    local y = 0
    for _, block in ipairs(blocks) do
        if block.Refresh then block:Refresh(height and height > 0 and height - y or nil) end
        if block:IsShown() then
            block:ClearAllPoints()
            block:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
            block:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -y)
            y = y + (tonumber(block:GetHeight()) or 0) + GAP
        end
    end
end

local function MainPage()
    panel = CreateFrame("Frame")
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", PAD, -PAD)
    title:SetText("Pathwright")
    local hint = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    hint:SetPoint("RIGHT", panel, "RIGHT", -PAD, 0)
    hint:SetJustifyH("LEFT")
    hint:SetText(
        T("/pw opens this page. The guide's actions are on its buttons and in the game's key bindings (Pathwright).")
    )
    content = CreateFrame("Frame", nil, panel)
    content:SetPoint("TOPLEFT", PAD, -64)
    content:SetPoint("BOTTOMRIGHT", -PAD, 8)
    for _, create in ipairs(Options.blocks) do
        local ok, block = pcall(create, content)
        if ok and block then
            blocks[#blocks + 1] = block
        elseif not ok then
            FG:Error("options", block)
        end
    end
    -- Called by the game when the page shows.
    content:SetScript("OnSizeChanged", function() Options:Refresh() end)
    panel.OnRefresh = function() Options:Refresh() end
    panel:SetScript("OnShow", function() Options:Refresh() end)
    return panel
end

-- The recordings: their count in the chat, the debug messages, clearing them (asked first).
StaticPopupDialogs["PATHWRIGHT_CLEAR_EVENTS"] = {
    text = T("Delete the quest events this character recorded for the app?"),
    button1 = YES,
    button2 = NO,
    OnAccept = function() FG.Collector:Reset() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

local function AdvancedPage(parent)
    local category = Settings.RegisterVerticalLayoutSubcategory(parent, T("Advanced"))
    local layout = SettingsPanel:GetLayout(category)
    layout:AddInitializer(Options.ButtonInitializer({
        label = "Recorded events",
        text = "Show in the chat",
        help = "How many quest events this character recorded, and how many the app does not have yet.",
        run = function() FG.Collector:PrintStatus() end,
    }))
    local debug = Settings.RegisterProxySetting(
        category,
        "Pathwright_debug",
        Settings.VarType.Boolean,
        T("Debug messages"),
        false,
        function() return type(PathwrightDB) == "table" and PathwrightDB.debug == true end,
        function(on)
            if type(PathwrightDB) == "table" then PathwrightDB.debug = on or nil end
        end
    )
    Settings.CreateCheckbox(category, debug, T("The addon's own messages in the chat, to find what goes wrong."))
    layout:AddInitializer(Options.ButtonInitializer({
        label = "Clear the recorded events",
        text = "Clear",
        help = "Deletes the quest events this character recorded for the app.",
        run = function() StaticPopup_Show("PATHWRIGHT_CLEAR_EVENTS") end,
    }))
end

--- Build the pages and register them in the game's options (once, at login: every part has
--- added its own by then).
function Options:Build()
    if self.category or not (Settings and Settings.RegisterCanvasLayoutCategory) then return end
    local category = Settings.RegisterCanvasLayoutCategory(MainPage(), "Pathwright")
    self.category = category
    for _, build in ipairs(self.pages) do
        FG:Try("options", build, category)
    end
    FG:Try("options", AdvancedPage, category)
    Settings.RegisterAddOnCategory(category)
    self:Refresh()
end

FG:On("PLAYER_LOGIN", function() Options:Build() end)

--- Open the game's options on the addon's main page. Not during combat (the game refuses): says so.
function Options:Open()
    if not self.category then return end
    if InCombatLockdown() then return FG:Print(T("the game's options open out of combat only")) end
    Settings.OpenToCategory(self.category:GetID())
end

function FG:OpenSettings() Options:Open() end
