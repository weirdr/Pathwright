-- Feedback: a speech bubble under the guide (Tabs.lua, left of the leaderboard's crown; or
-- "/pw feedback") opens a window that asks "What went wrong?". OK makes a report of what was
-- typed and of the game as it is then, enough to find a guide's mistake without asking: the
-- addon's and the game's versions, the character's level, class and race (never its name), where
-- it stands, the guide and its step with the steps around it, which of that step's quests are
-- done, the quest log with its progress, the target, the addon's last errors.
--
-- Two ways out of the game, which an addon cannot leave by itself:
--   The Pathwright Updater (crates/pathwright-updater) sends it. The report waits in the saved
--   variables (PathwrightDB.feedback: lines "PWFB1:<id>:<the report's JSON in base64>"), which
--   the game writes at a reload or a logout; the updater reads them there and posts them to the
--   project's relay, which opens the issue. It answers through Updater.lua (Pathwright.updater:
--   when it last ran, and the reports it sent with their issue's address), read at the next
--   login: the report sent leaves the list and its address is said in the chat.
--   Or by hand: the report shows in the window, selected, to copy (an addon cannot write to the
--   clipboard) and paste in a message to @Pathwright on Discord. That text is cut to fit one
--   Discord message (LIMIT): the least useful parts go first (Feedback.Fit).

local FG = Pathwright
local T = FG.T
local Readable = FG.Readable
local QuestLog = FG.QuestLog
local Feedback = {}
FG.Feedback = Feedback

--- The most a Discord message holds is 2000 characters: the pasted report stays under it.
local LIMIT = 1900
--- The most the player types, and the most a report sent by the updater weighs.
local MAX_INPUT, MAX_SENT = 500, 12000
--- Reports waiting for the updater: beyond that many the oldest goes.
local MAX_WAITING = 5
--- The updater is taken as running here when it was seen in the last days.
local UPDATER_DAYS = 14
local PREFIX = "PWFB1:"
local WIDTH, LEFT_W, TITLE_H, BODY_H = 580, 250, 28, 252

local L = {
    title = T("Feedback"),
    question = T("What went wrong?"),
    hint = T("Say what you expected and what happened instead."),
    ok = T("OK"),
    count = T("%d / %d"),
    sent = T("Sent with your words"),
    you = T("You"),
    where = T("Where"),
    guide = T("Guide"),
    quests = T("Quests"),
    addon = T("Addon"),
    level = T("Level %d"),
    step = T("%s, step %d of %d"),
    noGuide = T("no guide followed"),
    log = T("%d in your log, with their progress"),
    on = T("%s on %s"),
    later = T("The report shows here once you press OK."),
    noName = T("No character or account name is included."),
    empty = T("Type what went wrong first."),
    reload = T("Reload and send"),
    updater = T("The Pathwright Updater on this computer sends it once the game reloads. Or press %s and paste it to @Pathwright on Discord."),
    maybe = T("If the Pathwright Updater runs on this computer, it sends it once the game reloads. Otherwise press %s and paste it to @Pathwright on Discord."),
    done = T("your report was sent: %s"),
}

-- The report ------------------------------------------------------------------------------------

--- What a game function answers, unreadable values left out (nil when it fails).
local function Fact(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d = pcall(fn, ...)
    if not ok then return nil end
    return Readable(a), Readable(b), Readable(c), Readable(d)
end

--- A text cut to `bytes` at most, never in the middle of a character.
local function Cut(text, bytes)
    if #text <= bytes then return text end
    local last = bytes
    while last > 0 and text:byte(last + 1) and text:byte(last + 1) >= 128 and text:byte(last + 1) < 192 do
        last = last - 1
    end
    return text:sub(1, last)
end
Feedback.Cut = Cut

--- A step of the guide, short: its place in the route, kind, quest and name; `full`: all that
--- says what it asks and where.
local function Step(route, index, full)
    local s = route.steps[index]
    if not s then return nil end
    local out = { i = index, k = s.k, q = s.q, n = s.n }
    if full then
        out.o, out.e, out.id, out.c, out.ic = s.o, s.e, s.id, s.c, s.ic
        out.m, out.x, out.y = s.m, s.x, s.y
        out.t = type(s.t) == "string" and Cut(s.t, 120) or nil
    end
    return out
end

--- Which of a step's quests are done: its own and those it waits for ({ ["123"] = true }).
local function Done(step)
    local out, any = {}, false
    local function Add(questID)
        if type(questID) ~= "number" then return end
        local done = QuestLog.IsQuestFlaggedCompleted and Fact(QuestLog.IsQuestFlaggedCompleted, questID)
        out[tostring(questID)], any = done and true or false, true
    end
    Add(step.q)
    for _, list in ipairs({ step.pre or false, step.pa or false }) do
        for _, questID in ipairs(type(list) == "table" and list or {}) do
            Add(questID)
        end
    end
    return any and out or nil
end

--- The quest log: { questID, 1 complete / -1 failed / 0, { { have, need }... } } for each quest.
local function Log()
    local list = {}
    if not QuestLog.GetNumQuestLogEntries or not QuestLog.GetInfo then return list end
    for i = 1, Fact(QuestLog.GetNumQuestLogEntries) or 0 do
        local info = Fact(QuestLog.GetInfo, i)
        local questID = type(info) == "table" and not info.isHeader and Readable(info.questID)
        if type(questID) == "number" and questID > 0 and #list < 40 then
            local state = 0
            if QuestLog.IsComplete and Fact(QuestLog.IsComplete, questID) then
                state = 1
            elseif QuestLog.IsFailed and Fact(QuestLog.IsFailed, questID) then
                state = -1
            end
            local objectives = {}
            for _, o in ipairs(QuestLog.GetQuestObjectives and Fact(QuestLog.GetQuestObjectives, questID) or {}) do
                local have, need = tonumber(Readable(o.numFulfilled)) or 0, tonumber(Readable(o.numRequired)) or 0
                objectives[#objectives + 1] = { have, need }
            end
            list[#list + 1] = { questID, state, objectives }
        end
    end
    return list
end

--- The addon's errors counted most (PathwrightDB.errors), a few of them.
local function Errors()
    local list = {}
    for message, count in pairs(type(PathwrightDB) == "table" and PathwrightDB.errors or {}) do
        list[#list + 1] = { message = tostring(message), count = tonumber(count) or 1 }
    end
    table.sort(list, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.message < b.message
    end)
    local out = {}
    for i = 1, math.min(3, #list) do
        out[i] = Cut(list[i].message, 140) .. " x" .. list[i].count
    end
    return out[1] and out or nil
end

--- The report of `words` and of the game now, as a table (Feedback.Text makes it text).
function Feedback:Report(words)
    local metadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
    local version, build, _, interface = Fact(GetBuildInfo)
    local _, class = Fact(UnitClass, "player")
    local _, race = Fact(UnitRace, "player")
    local report = {
        report = "pathwright-feedback",
        v = 1,
        what_went_wrong = words,
        at = date and date("!%Y-%m-%dT%H:%MZ") or nil,
        addon = {
            release = FG.release,
            guide = Fact(metadata, "Pathwright_Guide", "Version"),
            profile = Fact(metadata, "Pathwright_Profile", "Version"),
        },
        client = { version = version, build = build, interface = interface, locale = Fact(GetLocale) },
        char = {
            level = Fact(UnitLevel, "player"),
            xp = Fact(UnitXP, "player"),
            xp_max = Fact(UnitXPMax, "player"),
            rested = Fact(GetXPExhaustion),
            class = class,
            race = race,
            faction = Fact(UnitFactionGroup, "player"),
            dead = Fact(UnitIsDeadOrGhost, "player") and true or nil,
            group = (Fact(GetNumGroupMembers) or 0) > 0 and Fact(GetNumGroupMembers) or nil,
            instance = Fact(IsInInstance) and true or nil,
        },
        quests = Log(),
        errors = Errors(),
    }
    local map, x, y = Fact(FG.PlayerPosition)
    local sub = Fact(GetSubZoneText)
    report.place = {
        zone = Fact(GetRealZoneText),
        sub = sub ~= "" and sub or nil,
        map = map,
        x = x,
        y = y,
        hearth = Fact(GetBindLocation),
    }
    local Guide = FG.Guide
    local route, state = Guide and Guide:Route(), Guide and Guide:State()
    if route and state and route.steps then
        local index = tonumber(state.step) or 1
        local guide = {
            name = Guide:RouteName(),
            builtin = route.builtin and true or nil,
            mode = FG:Get("guideMode"),
            step = index,
            of = #route.steps,
            now = Step(route, index, true),
            prev = Step(route, index - 1),
            next = { Step(route, index + 1), Step(route, index + 2) },
            done = route.steps[index] and Done(route.steps[index]) or nil,
        }
        local skipped = {}
        for questID in pairs(type(state.skippedQuests) == "table" and state.skippedQuests or {}) do
            if type(questID) == "number" and #skipped < 12 then skipped[#skipped + 1] = questID end
        end
        table.sort(skipped)
        guide.skipped = skipped[1] and skipped or nil
        report.guide = guide
    end
    if UnitExists and Fact(UnitExists, "target") and UnitGUID then
        local kind, npc = FG.ParseGUID(UnitGUID("target"))
        if kind == "npc" then report.target = { npc = npc, name = Fact(UnitName, "target") } end
    end
    return report
end

--- What is asked of who reads the report, then the report as JSON.
local function Wrapped(report)
    return "Please open a GitHub issue from this report.\n```json\n" .. FG.JSON(report) .. "\n```"
end

--- The report as the text to paste, within `limit` characters: when it is too long, the parts
--- that say least go, one after the other (`cut` says so in what is left).
function Feedback.Fit(report, limit)
    limit = limit or LIMIT
    local text = Wrapped(report)
    local trims = {
        function() report.errors = nil end,
        function()
            if report.guide then report.guide.next, report.guide.prev = nil, nil end
        end,
        function()
            for _, quest in ipairs(report.quests or {}) do
                quest[3] = nil
            end
        end,
        function()
            local quests = report.quests or {}
            if #quests > 12 then
                report.more_quests = #quests - 12
                for i = #quests, 13, -1 do
                    quests[i] = nil
                end
            end
        end,
        function()
            if report.guide and report.guide.now then report.guide.now.t = nil end
            local words = report.what_went_wrong
            if type(words) == "string" then report.what_went_wrong = Cut(words, 240) end
        end,
        function() report.quests, report.place, report.target = nil, nil, nil end,
    }
    for _, trim in ipairs(trims) do
        if #text <= limit then break end
        trim()
        report.cut = true
        text = Wrapped(report)
    end
    return text
end

--- The text to paste on Discord for `words`.
function Feedback:Text(words) return Feedback.Fit(self:Report(words)) end

-- The updater -----------------------------------------------------------------------------------

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

--- A text in base64 (the standard alphabet, padded): nothing in it for the saved variables to
--- escape, so the updater reads it as it is.
function Feedback.Base64(text)
    local out = {}
    for i = 1, #text, 3 do
        local a, b, c = text:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1, c2 = math.floor(n / 262144) % 64, math.floor(n / 4096) % 64
        local c3, c4 = math.floor(n / 64) % 64, n % 64
        out[#out + 1] = B64:sub(c1 + 1, c1 + 1)
            .. B64:sub(c2 + 1, c2 + 1)
            .. (b and B64:sub(c3 + 1, c3 + 1) or "=")
            .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
    end
    return table.concat(out)
end

--- Whether the Pathwright Updater runs on this computer: it said so lately (Updater.lua).
function Feedback.HasUpdater()
    local seen = type(FG.updater) == "table" and tonumber(FG.updater.at) or nil
    return seen ~= nil and time() - seen < UPDATER_DAYS * 86400
end

--- The reports waiting for the updater (PathwrightDB.feedback).
local function Waiting()
    if type(PathwrightDB) ~= "table" then return {} end
    if type(PathwrightDB.feedback) ~= "table" then PathwrightDB.feedback = {} end
    return PathwrightDB.feedback
end

--- Leave a report for the updater: the game writes it to disk at the next reload or logout.
--- Returns its id.
function Feedback:Queue(report)
    local id = string.format("%d-%04x", time(), math.random(0, 65535))
    report.id = id
    local json = FG.JSON(report)
    if #json > MAX_SENT then
        report.quests, report.errors, report.cut = nil, nil, true
        json = FG.JSON(report)
    end
    local waiting = Waiting()
    waiting[#waiting + 1] = PREFIX .. id .. ":" .. Feedback.Base64(json)
    while #waiting > MAX_WAITING do
        table.remove(waiting, 1)
    end
    return id
end

--- At login: the reports the updater says it sent leave the list, their issue said in the chat.
function Feedback:Acknowledge()
    local sent = type(FG.updater) == "table" and type(FG.updater.sent) == "table" and FG.updater.sent or {}
    local waiting = Waiting()
    for i = #waiting, 1, -1 do
        local id = type(waiting[i]) == "string" and waiting[i]:match("^PWFB1:([%w%-]+):")
        local url = id and sent[id]
        if url then
            table.remove(waiting, i)
            if type(url) == "string" and FG.Print then FG:Print(L.done, url) end
        elseif not id then
            table.remove(waiting, i)
        end
    end
end

-- The window ------------------------------------------------------------------------------------

local function CopyKey() return IsMacClient and IsMacClient() and "Cmd+C" or "Ctrl+C" end

--- A flat button of the window: `primary` in the accent's colors.
local function Flat(parent, label, width, primary)
    local P = FG.Panel
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(width, 22)
    local edge = FG.Skin.colors[primary and "accent" or "edge"]
    b.edge = P.Solid(b, "BACKGROUND", edge[1], edge[2], edge[3], 1)
    b.edge:SetAllPoints()
    b.fill = b:CreateTexture(nil, "BORDER")
    b.fill:SetPoint("TOPLEFT", 1, -1)
    b.fill:SetPoint("BOTTOMRIGHT", -1, 1)
    if primary then
        P.Fade(b.fill, { 0.42, 0.48, 1 }, { 0.15, 0.2, 0.72 })
    else
        local bg = FG.Skin.colors.bg
        b.fill:SetColorTexture(bg[1], bg[2], bg[3], 1)
    end
    b.label = P.Text(b, 11, "text", nil, "CENTER")
    b.label:SetPoint("CENTER", 0, 0)
    b.label:SetText(label)
    return b
end

--- A box to type in (or to copy from): several lines, scrolled with the wheel, a hint shown
--- while it is empty. Returns its frame; `box.edit` is the text itself.
local function Box(parent, width, height, hint)
    local P = FG.Panel
    local box = CreateFrame("Frame", nil, parent)
    box:SetSize(width, height)
    local edge = FG.Skin.colors.edge
    box.edge = P.Solid(box, "BACKGROUND", edge[1], edge[2], edge[3], 1)
    box.edge:SetAllPoints()
    box.fill = P.Solid(box, "BORDER", 0.008, 0.02, 0.043, 0.9)
    box.fill:SetPoint("TOPLEFT", 1, -1)
    box.fill:SetPoint("BOTTOMRIGHT", -1, 1)
    local scroll = CreateFrame("ScrollFrame", nil, box)
    scroll:SetPoint("TOPLEFT", 8, -6)
    scroll:SetPoint("BOTTOMRIGHT", -8, 6)
    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject(FG.Skin.FontObject(11))
    edit:SetTextColor(1, 1, 1)
    edit:SetWidth(width - 16)
    scroll:SetScrollChild(edit)
    box.hint = P.Text(box, 11, "muted", width - 16)
    box.hint:SetPoint("TOPLEFT", 8, -6)
    box.hint:SetWordWrap(true)
    box.hint:SetText(hint or "")
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local now, most = tonumber(self:GetVerticalScroll()) or 0, tonumber(self:GetVerticalScrollRange()) or 0
        self:SetVerticalScroll(math.max(0, math.min(most, now - (tonumber(delta) or 0) * 24)))
    end)
    -- The view follows the cursor as lines are typed.
    edit:SetScript("OnCursorChanged", function(_, _, y, _, lineHeight)
        local top, view = tonumber(scroll:GetVerticalScroll()), tonumber(scroll:GetHeight())
        y, lineHeight = tonumber(y), tonumber(lineHeight)
        if not (top and view and y and lineHeight) then return end
        if -y < top then
            scroll:SetVerticalScroll(-y)
        elseif -y + lineHeight > top + view then
            scroll:SetVerticalScroll(-y + lineHeight - view)
        end
    end)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    box:EnableMouse(true)
    box:SetScript("OnMouseDown", function() edit:SetFocus() end)
    box.edit, box.scroll = edit, scroll
    return box
end

local function Typed(edit)
    local text = edit:GetText()
    return type(text) == "string" and text or ""
end

local function Trimmed(text) return (text:gsub("^%s+", ""):gsub("%s+$", "")) end

--- The lines of "Sent with your words": what the report holds, in plain words.
local function Facts(report)
    local char, place, guide, addon = report.char or {}, report.place or {}, report.guide, report.addon or {}
    local class, race = Fact(UnitClass, "player"), Fact(UnitRace, "player")
    local you = string.format(L.level, tonumber(char.level) or 0)
    for _, word in ipairs({ race or false, class or false }) do
        if type(word) == "string" then you = you .. " " .. word end
    end
    local where = tostring(place.zone or "?")
    if place.x and place.y then where = string.format("%s %.1f, %.1f", where, place.x, place.y) end
    local following = L.noGuide
    if guide then following = string.format(L.step, tostring(guide.name or "?"), guide.step or 0, guide.of or 0) end
    local release = tostring(addon.release or addon.guide or "?")
    return {
        { L.you, you },
        { L.where, where },
        { L.guide, following },
        { L.quests, string.format(L.log, #(report.quests or {})) },
        { L.addon, string.format(L.on, release, tostring((report.client or {}).version or "?")) },
    }
end

local function Build()
    local P = FG.Panel
    local frame = CreateFrame("Frame", "PathwrightFeedback", FG.UIRoot, "BackdropTemplate")
    frame:SetSize(WIDTH, TITLE_H + BODY_H + 2)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    FG:Draggable(frame)
    frame.fade = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
    frame.fade:SetPoint("TOPLEFT", 1, -1)
    frame.fade:SetPoint("BOTTOMRIGHT", -1, 1)
    P.Fade(frame.fade, { 0.02, 0.035, 0.07 }, { 0.11, 0.157, 0.29 }, 0.94, 0.94)
    frame.wash = frame:CreateTexture(nil, "BACKGROUND", nil, 2)
    frame.wash:SetPoint("TOPLEFT", 1, -1)
    frame.wash:SetPoint("TOPRIGHT", -1, -1)
    frame.wash:SetHeight(TITLE_H - 1)
    P.Wash(frame.wash, "accent", 0.42, 0)
    frame.title = P.Text(frame, 13, "text")
    frame.title:SetPoint("TOPLEFT", 10, -8)
    frame.title:SetText(L.title)
    frame.close = P.CloseButton(frame)

    -- On the left: the question, where to answer it, OK.
    frame.question = P.Text(frame, 12, "text")
    frame.question:SetPoint("TOPLEFT", 10, -TITLE_H - 12)
    frame.question:SetText(L.question)
    frame.input = Box(frame, LEFT_W - 20, 150, L.hint)
    frame.input:SetPoint("TOPLEFT", 10, -TITLE_H - 34)
    frame.input.edit:SetMaxLetters(MAX_INPUT)
    frame.count = P.Text(frame, 10, "muted")
    frame.count:SetPoint("TOPLEFT", frame.input, "BOTTOMLEFT", 0, -12)
    frame.ok = Flat(frame, L.ok, 64, true)
    frame.ok:SetPoint("TOPRIGHT", frame.input, "BOTTOMRIGHT", 0, -8)
    frame.ok:SetScript("OnClick", function() Feedback:Submit() end)
    frame.input.edit:SetScript("OnTextChanged", function(self)
        local text = Typed(self)
        frame.input.hint:SetShown(text == "")
        frame.count:SetText(string.format(L.count, strlenutf8 and strlenutf8(text) or #text, MAX_INPUT))
    end)

    -- On the right: what is sent with those words, then the report once OK is pressed.
    local pane = CreateFrame("Frame", nil, frame)
    pane:SetPoint("TOPLEFT", LEFT_W, -TITLE_H)
    pane:SetPoint("BOTTOMRIGHT", -1, 1)
    local edge = FG.Skin.colors.edge
    local side = P.Solid(pane, "BORDER", edge[1], edge[2], edge[3], 1)
    side:SetPoint("TOPLEFT", 0, 0)
    side:SetPoint("BOTTOMLEFT", 0, 0)
    side:SetWidth(1)
    pane.back = pane:CreateTexture(nil, "BACKGROUND", nil, 3)
    pane.back:SetAllPoints()
    P.Fade(pane.back, { 0.008, 0.02, 0.043 }, FG.Skin.colors.accent, 0.45, 0.1)
    pane.heading = P.Text(pane, 10, "muted")
    pane.heading:SetPoint("TOPLEFT", 10, -12)
    pane.heading:SetText(L.sent)
    pane.facts = {}
    local paneWidth = WIDTH - LEFT_W - 1
    for i = 1, 5 do
        local name = P.Text(pane, 10, "muted", 52)
        name:SetPoint("TOPLEFT", 10, -14 - i * 16)
        local value = P.Text(pane, 11, "text2", paneWidth - 76)
        value:SetPoint("TOPLEFT", 64, -13 - i * 16)
        pane.facts[i] = { name = name, value = value }
    end
    frame.pane = pane
    frame.output = Box(pane, paneWidth - 20, 64, L.later)
    frame.output:SetPoint("TOPLEFT", 10, -116)
    -- The report is to copy, not to edit: a key pressed in it leaves it as it was.
    frame.output.edit:SetScript("OnTextChanged", function(self, user)
        if user and Feedback.text then
            self:SetText(Feedback.text)
            self:HighlightText()
        end
    end)
    frame.output.edit:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    frame.note = P.Text(pane, 10, "text2", paneWidth - 20)
    frame.note:SetPoint("TOPLEFT", frame.output, "BOTTOMLEFT", 0, -8)
    frame.note:SetWordWrap(true)
    frame.note:SetJustifyV("TOP")
    frame.reload = Flat(pane, L.reload, 120, true)
    frame.reload:SetPoint("BOTTOMRIGHT", -10, 10)
    frame.reload:SetScript("OnClick", function()
        if ReloadUI then ReloadUI() end
    end)
    FG.Skin:Style(frame, "panel", { frame.title })
    if UISpecialFrames then table.insert(UISpecialFrames, "PathwrightFeedback") end
    frame:Hide()
    return frame
end

--- Show the window as it is before OK: what would be sent, no report yet.
function Feedback:Fill()
    local frame = self.frame
    self.text = nil
    for i, fact in ipairs(Facts(self:Report(""))) do
        local row = frame.pane.facts[i]
        row.name:SetText(fact[1])
        row.value:SetText(fact[2])
    end
    frame.output.edit:SetText("")
    frame.output.hint:Show()
    local muted = FG.Skin.colors.text2
    frame.note:SetTextColor(muted[1], muted[2], muted[3])
    frame.note:SetText(L.noName)
    frame.reload:Hide()
end

--- OK: make the report of what was typed (or of `words`), leave it for the updater, and show
--- it selected to copy. The window stays open. Returns the text to paste, nil without words.
function Feedback:Submit(words)
    local frame = self.frame
    if words == nil and frame then words = Typed(frame.input.edit) end
    words = Trimmed(type(words) == "string" and words or "")
    if #words < 3 then
        if frame then
            local red = FG.Skin.colors.red
            frame.note:SetTextColor(red[1], red[2], red[3])
            frame.note:SetText(L.empty)
        end
        return nil
    end
    words = Cut(words, MAX_INPUT * 4)
    self.id = self:Queue(self:Report(words))
    self.text = self:Text(words)
    if frame then
        local output = frame.output
        output.hint:Hide()
        output.edit:SetText(self.text)
        output.edit:SetFocus()
        output.edit:HighlightText()
        output.edit:SetCursorPosition(0)
        local muted = FG.Skin.colors.text2
        frame.note:SetTextColor(muted[1], muted[2], muted[3])
        -- The updater says it runs here through Updater.lua, read at login: one started since
        -- then is not known yet, so the reload is offered either way.
        frame.note:SetText(string.format(Feedback.HasUpdater() and L.updater or L.maybe, CopyKey()))
        frame.reload:Show()
    end
    return self.text
end

--- Open or close the window.
function Feedback:Toggle()
    if not self.frame then self.frame = Build() end
    local frame = self.frame
    if frame:IsShown() then return frame:Hide() end
    frame.input.edit:SetText("")
    frame.input.hint:Show()
    frame.count:SetText(string.format(L.count, 0, MAX_INPUT))
    self:Fill()
    frame:Show()
    frame.input.edit:SetFocus()
end

FG:On("PLAYER_LOGIN", function() FG:Try("feedback", Feedback.Acknowledge, Feedback) end)
