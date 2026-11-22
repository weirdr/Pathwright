-- Convert a Zygor guide into the built-in guide format, as a reference to check our own guides
-- against (addon/tools/guide_compare.lua). Zygor's guides are Zygor's: never ship the output.
-- The built-in guides are written by hand (addon/guides) and built with guide_build.py.
--
--   luajit addon/tools/zygor_convert.lua <Zygor guide file> <guide title, or part of it>
--       [--race <race name, or part of it>] [--db data/forever.sqlite.zst]
--       [--out debug/zygor] [--name <guide name in Pathwright>]
--
-- Run from the repository root. Needs zstd and sqlite3 (the game data of the edition: zone maps,
-- races, classes, quest levels).
--
-- The guide file is run as Zygor would run it, with a stand-in for ZygorGuidesViewer that keeps
-- what RegisterGuide is given. The guide is then written once for every race of it (--race, else
-- its "defaultfor" line) and every class that race can be, with each faction its race has: a
-- variant. A step or line of the guide with "|only if" is kept for the variants whose condition
-- holds (the condition is Lua, run with the variant's race, class and faction; what depends on
-- the moment in game, a subzone, a quest in the log, is taken as at a fresh start). The addon
-- builds the route of the character's variant (Builtin.lua).
--
-- What becomes what:
--   talk Name##id               the NPC of the step's accept, turn-in, training, hearth, flight path
--   accept / turnin Quest##id   accept / turnin
--   kill, collect, click, clicknpc, use, and any line with "|q quest/objective": objective
--   Train ... |trainer, Sell ... |vendor, home, fpath, ding level,xp: train, sell, bind,
--                               flight_master, grind
--   a line with "|goto" only (Enter the cave):  goto (done within its "< yards", else 20)
--   Click Here to Continue |confirm, and lines of text: note (done when marked)
--   |tip                        the notes of the step
--   stickystart "label"         the labelled step's objectives, along the way (bg) from there

local args = { ... }
local ROOT = "."

local function Fail(msg)
    io.stderr:write("zygor_convert: " .. msg .. "\n")
    os.exit(1)
end

-- Arguments -----------------------------------------------------------------------------------

local opts = { db = "data/forever.sqlite.zst", out = "debug/zygor" }
local positional = {}
do
    local i = 1
    while i <= #args do
        local a = args[i]
        if a:sub(1, 2) == "--" then
            opts[a:sub(3)] = args[i + 1]
            i = i + 2
        else
            table.insert(positional, a)
            i = i + 1
        end
    end
end
local guideFile, wanted = positional[1], positional[2]
if not guideFile or not wanted then
    Fail("usage: luajit addon/tools/zygor_convert.lua <Zygor guide file> <guide title> [--race NAME] [--db FILE]")
end

-- The game data ---------------------------------------------------------------------------------

local function Quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local dbPath = opts.db
if dbPath:match("%.zst$") then
    local tmp = os.tmpname() .. ".sqlite"
    assert(os.execute("zstd -q -d -c " .. Quote(dbPath) .. " > " .. Quote(tmp)) == 0, "zstd failed on " .. dbPath)
    dbPath = tmp
end

--- Rows of a query, each a list of its columns (text).
local function Query(sql)
    local p = assert(io.popen("sqlite3 -separator '\t' " .. Quote(dbPath) .. " " .. Quote(sql)))
    local rows = {}
    for line in p:lines() do
        local row = {}
        for field in (line .. "\t"):gmatch("([^\t]*)\t") do
            table.insert(row, field)
        end
        table.insert(rows, row)
    end
    p:close()
    return rows
end

--- Zone name -> uiMapID: the zone map (type 3) with a parent, not a system one, the lowest ID.
local maps = {}
for _, r in ipairs(Query("SELECT ID, Name_lang, ParentUiMapID, Type, System FROM client_uimap ORDER BY ID")) do
    local id, name, parent, kind, system = tonumber(r[1]), r[2], tonumber(r[3]), tonumber(r[4]), tonumber(r[5])
    local good = kind == 3 and parent ~= 0 and system == 0
    local have = maps[name]
    if not have or (good and not have.good) then maps[name] = { id = id, good = good } end
end

local classes = {}
for _, r in ipairs(Query("SELECT ID, Name_lang FROM client_chrclasses")) do
    classes[tonumber(r[1])] = r[2]
end
local races = {}
for _, r in ipairs(Query("SELECT ID, Name_lang, Alliance FROM client_chrraces")) do
    races[tonumber(r[1])] = { name = r[2], faction = tonumber(r[3]) == 1 and "Horde" or "Alliance" }
end
local classesOf = {}
for _, r in ipairs(Query("SELECT RaceID, ClassID FROM client_charbaseinfo ORDER BY ClassID")) do
    local race, class = tonumber(r[1]), tonumber(r[2])
    classesOf[race] = classesOf[race] or {}
    table.insert(classesOf[race], class)
end
local questLevel = {}
for _, r in ipairs(Query("SELECT id, level, min_level FROM m_quest")) do
    questLevel[tonumber(r[1])] = math.max(tonumber(r[2]) or 0, tonumber(r[3]) or 0)
end

-- The Zygor guide ----------------------------------------------------------------------------------

local registered = {}
local function Stub()
    return setmetatable({}, {
        __index = function() return Stub() end,
        __call = function() return nil end,
    })
end
local zgv = Stub()
rawset(
    zgv,
    "RegisterGuide",
    function(_, title, header, text) table.insert(registered, { title = title, header = header, text = text }) end
)
rawset(zgv, "DoMutex", function() return false end)
rawset(zgv, "IMAGESDIR", "")
-- The faction files (ZygorLevelingHordeCLASSIC...) load only for their faction.
local env = setmetatable({
    ZygorGuidesViewer = zgv,
    ZGV = zgv,
    UnitFactionGroup = function() return guideFile:find("Horde") and "Horde" or "Alliance" end,
}, { __index = _G })
local chunk = assert(loadfile(guideFile))
setfenv(chunk, env)
local ok, err = pcall(chunk)
if not ok then Fail("running " .. guideFile .. ": " .. tostring(err)) end

local guide
for _, g in ipairs(registered) do
    if g.title == wanted or g.title:find(wanted, 1, true) then
        if guide then Fail('several guides match "' .. wanted .. '": ' .. guide.title .. ", " .. g.title) end
        guide = g
    end
end
if not guide then Fail('no guide matches "' .. wanted .. '" in ' .. guideFile) end
local text = type(guide.text) == "string" and guide.text or Fail("the guide has no text")

local shortTitle = guide.title:match("([^\\]+)$")
local name = opts.name or shortTitle
local fromLevel, toLevel = shortTitle:match("%((%d+)%-(%d+)%)")
fromLevel, toLevel = tonumber(fromLevel) or 1, tonumber(toLevel) or 60

-- The variants: every class of the guide's races.
local raceWanted = opts.race or text:match("defaultfor%s+([%w ]+)")
if not raceWanted then Fail("which race? (--race)") end
raceWanted = raceWanted:gsub("%s+$", "")
local variants = {}
for raceID, race in pairs(races) do
    if race.name:lower():find(raceWanted:lower(), 1, true) then
        for _, classID in ipairs(classesOf[raceID] or {}) do
            table.insert(variants, { race = raceID, class = classID, faction = race.faction })
        end
    end
end
table.sort(variants, function(a, b)
    if a.race ~= b.race then return a.race < b.race end
    return a.class < b.class
end)
if not variants[1] then Fail('no playable race named like "' .. raceWanted .. '"') end

-- Conditions -------------------------------------------------------------------------------------------

--- Whether `cond` (Lua, as Zygor's "|only if") holds for variant `v`. A condition that fails to
--- run keeps the line.
local function Holds(cond, v)
    if not cond or cond == "" then return true end
    local e = {}
    e.Alliance, e.Horde = v.faction == "Alliance", v.faction == "Horde"
    for id, className in pairs(classes) do
        e[className:gsub("%s", "")] = id == v.class
    end
    local raceName = races[v.race].name
    for word in raceName:gmatch("%a+") do
        e[word] = true
    end
    e[raceName:gsub("[%s']", "")] = true
    e.level = fromLevel
    local function no() return false end
    e.hardcore, e.subzone, e.indoors, e.haveq, e.readyq, e.completedq, e.walking = no, no, no, no, no, no, false
    e.isdead = false
    e.skill = function() return 0 end
    e.raceclass = function(x)
        x = tostring(x):lower()
        return raceName:lower():find(x, 1, true) ~= nil or (classes[v.class] or ""):lower() == x
    end
    local f = loadstring("return " .. cond)
    if not f then return true end
    setfenv(f, e)
    local okRun, result = pcall(f)
    if not okRun then return true end
    return result and true or false
end

-- Parsing ----------------------------------------------------------------------------------------------

local function Clean(s)
    s = s:gsub("{%a}", ""):gsub("{}", ""):gsub("_", "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " "))
end

--- "8 Pesky Cirrusfly##251169" -> count, name, id (id nil without ##).
local function Thing(s)
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    local count, rest = s:match("^(%d+)%s+(.+)$")
    rest = rest or s
    local thingName, id = rest:match("^(.-)##(%d+)")
    if thingName then return tonumber(count), Clean(thingName), tonumber(id) end
    return tonumber(count), Clean(rest), nil
end

--- A goal line: its head (the text before the first "|") and its modifiers.
local function Line(raw)
    local head, rest = raw:match("^([^|]*)(.*)$")
    local m = {}
    for piece in rest:gmatch("|([^|]*)") do
        local key, value = piece:match("^(%a+)%s*(.-)%s*$")
        if key then
            if key == "tip" then
                m.tips = m.tips or {}
                table.insert(m.tips, Clean(value))
            else
                m[key] = value
            end
        end
    end
    return Clean(head), m
end

local lastZone
--- "|goto Zephras Isle/0 42.83,23.39 < 15" -> m, x, y, radius.
local function Place(value)
    if not value then return nil end
    local zone, x, y, radius = value:match("^(.-)%s*(%d+%.?%d*),%s*(%d+%.?%d*)%s*<?%s*(%d*)")
    if not x then return nil end
    zone = zone:gsub("/%d+$", ""):gsub("%s+$", "")
    if zone == "" then zone = lastZone end
    lastZone = zone
    local map = zone and maps[zone]
    if not map then
        io.stderr:write('zygor_convert: no map for zone "' .. tostring(zone) .. '"\n')
        return nil
    end
    return { m = map.id, x = tonumber(x), y = tonumber(y), r = tonumber(radius) }
end

-- The steps of the guide, as Zygor blocks: { lines, labels, sticky }.
local blocks, labels = {}, {}
do
    local current
    for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
        local line = raw:gsub("^%s+", ""):gsub("%s+$", "")
        if line == "step" then
            current = { lines = {}, sticky = {} }
            table.insert(blocks, current)
        elseif current and line ~= "" then
            local label = line:match('^label%s+"(.-)"')
            local sticky = line:match('^stickystart%s+"(.-)"')
            if label then
                labels[label] = #blocks
            elseif sticky then
                -- A stickystart line stands before the step it goes with (Zygor writes it last
                -- in the step before): kept for the next step.
                current.stickyNext = current.stickyNext or {}
                table.insert(current.stickyNext, sticky)
            elseif not line:match("^stickystop") and line:sub(1, 1) ~= "'" then
                table.insert(current.lines, line)
            end
        end
    end
    for i, b in ipairs(blocks) do
        if b.stickyNext and blocks[i + 1] then blocks[i + 1].sticky = b.stickyNext end
    end
end

-- Converting -----------------------------------------------------------------------------------------

local steps = {}

--- The variants (indexes) `cond` holds for, among `among`.
local function Keep(among, cond)
    local out = {}
    for _, i in ipairs(among) do
        if Holds(cond, variants[i]) then table.insert(out, i) end
    end
    return out
end

local ALL = {}
for i = 1, #variants do
    ALL[i] = i
end

local function Emit(step, only)
    if not only[1] then return end
    if #only < #variants then step.only = only end
    table.insert(steps, step)
    return step
end

local VERBS = {
    trash = "Destroy",
    buy = "Buy",
    use = "Use",
    click = "Click",
    clicknpc = "Click",
    collect = "Collect",
    kill = "Kill",
}

--- The steps of one Zygor block, for the variants `only`; `bg`: along the way (a sticky).
local function Convert(block, only, bg)
    -- The step's own condition: its lines that are "|only if" alone.
    for _, line in ipairs(block.lines) do
        local cond = line:match("^|only if%s+(.+)$")
        if cond then only = Keep(only, cond) end
    end
    if not only[1] then return end
    local npc, texts, tips, made, hints = nil, {}, {}, {}, {}
    local objectives = {}
    local function Add(step, lineOnly, m)
        step.nt = nil
        local place = m and Place(m["goto"])
        if place then
            step.m, step.x, step.y = place.m, place.x, place.y
            if step.k == "goto" then step.r = place.r end
        end
        if bg and step.k == "objective" then step.bg = true end
        local s = Emit(step, lineOnly)
        if s then table.insert(made, s) end
        return s
    end
    for _, raw in ipairs(block.lines) do
        if raw:match("^|tip") then
            table.insert(tips, Clean(raw:gsub("^|tip%s*", "")))
        elseif not raw:match("^|only if") and not raw:match("^|next") then
            local head, m = Line(raw)
            for _, t in ipairs(m.tips or {}) do
                table.insert(tips, t)
            end
            local lineOnly = Keep(only, m.only and m.only:gsub("^if%s+", ""))
            if lineOnly[1] then
                -- Zygor's commands are lower case ("kill"); text is not ("Kill enemies").
                local word, rest = head:match("^(%l+)%s+(.*)$")
                if not word then
                    word, rest = head:match("^(%l+)$"), ""
                end
                local q, o = (m.q or ""):match("^(%d+)/?(%d*)")
                q, o = tonumber(q), tonumber(o)
                if word == "talk" then
                    local _, n, id = Thing(rest)
                    npc = { id = id, name = n }
                elseif word == "accept" or word == "turnin" then
                    local _, questName, id = Thing(rest)
                    local verb = word == "accept" and "Accept " or "Turn in "
                    local step = { k = word, q = id, t = verb .. questName }
                    if npc then
                        step.t = step.t .. (word == "accept" and " from " or " to ") .. npc.name
                        step.e, step.id, step.n = "npc", npc.id, npc.name
                    end
                    Add(step, lineOnly, m)
                elseif
                    q
                    and o
                    and (word == "kill" or word == "collect" or word == "click" or word == "clicknpc" or word == "use")
                then
                    local count, thingName, id = Thing(rest)
                    local key = q .. "/" .. o
                    local place = Place(m["goto"])
                    if objectives[key] then
                        -- The same objective again (|count): another place to look.
                        if place then
                            objectives[key].spots = objectives[key].spots or {}
                            table.insert(objectives[key].spots, { m = place.m, x = place.x, y = place.y })
                        end
                    else
                        local step = { k = "objective", q = q, o = o }
                        if word == "kill" then
                            step.t = "Kill " .. (count and count .. " " or "") .. thingName
                            step.e, step.id, step.n = "npc", id, thingName
                            step.mobs, step.mi = { thingName }, id and { id } or nil
                            step.ic = "kill"
                        elseif word == "collect" then
                            step.t = "Collect " .. (count and count .. " " or "") .. thingName
                            step.e, step.id, step.n, step.c = "item", id, thingName, count
                            step.ic = "get"
                        elseif word == "click" then
                            step.t = "Click " .. thingName
                            step.e, step.id, step.n = "object", id, thingName
                            step.ic = "use"
                        elseif word == "clicknpc" then
                            step.t = "Click " .. thingName
                            step.e, step.id, step.n = "npc", id, thingName
                            step.ic = "use"
                        else
                            step.t = "Use " .. thingName
                            step.e, step.id, step.n = "item", id, thingName
                            step.ic = "use"
                        end
                        objectives[key] = Add(step, lineOnly, m)
                    end
                elseif q and o then
                    -- Any other line on an objective (Speak with, Tame, Find, Heal...).
                    local key = q .. "/" .. o
                    local place = Place(m["goto"])
                    if objectives[key] then
                        if place then
                            objectives[key].spots = objectives[key].spots or {}
                            table.insert(objectives[key].spots, { m = place.m, x = place.x, y = place.y })
                        end
                    else
                        objectives[key] = Add({ k = "objective", q = q, o = o, t = head }, lineOnly, m)
                    end
                elseif m.trainer or (word == "train") then
                    local _, n, id = Thing(m.trainer or "")
                    local who = id and { id = id, name = n } or npc
                    local step = { k = "train", t = "Train abilities" .. (who and " from " .. who.name or "") }
                    if who then
                        step.e, step.id, step.n = "npc", who.id, who.name
                    end
                    Add(step, lineOnly, m)
                elseif m.vendor then
                    local _, n, id = Thing(m.vendor)
                    Add({ k = "sell", t = "Sell items to " .. n, e = "npc", id = id, n = n }, lineOnly, m)
                elseif word == "home" then
                    local step = { k = "bind", t = "Set your hearthstone at " .. Clean(rest) }
                    if npc then
                        step.e, step.id, step.n = "npc", npc.id, npc.name
                    end
                    Add(step, lineOnly, m)
                elseif word == "fpath" then
                    local step = { k = "flight_master", t = "Get the flight path at " .. Clean(rest) }
                    if npc then
                        step.e, step.id, step.n = "npc", npc.id, npc.name
                    end
                    Add(step, lineOnly, m)
                elseif word == "ding" then
                    local level, xp = rest:match("^(%d+),?%s*(%d*)")
                    local prefix = texts[1] and (table.concat(texts, ". ") .. ": ") or ""
                    Add({
                        k = "grind",
                        t = prefix .. "reach level " .. level .. (xp ~= "" and " (" .. xp .. " XP)" or ""),
                        lvl = tonumber(level),
                        xp = tonumber(xp),
                    }, lineOnly, m)
                    texts = {}
                elseif m.complete or m.havebuff then
                    -- Done by something only the player sees (died, a buff): marked by hand.
                    Add({ k = "note", t = head }, lineOnly, m)
                elseif m.confirm ~= nil then
                    local t = texts[1] and table.concat(texts, ": ") or head
                    Add({ k = "note", t = t }, lineOnly, m)
                    texts = {}
                elseif m["goto"] and head ~= "" then
                    local t = head
                    if word and VERBS[word] then
                        local count, thingName = Thing(rest)
                        t = VERBS[word] .. " " .. (count and count .. " " or "") .. thingName
                    end
                    Add({ k = "goto", t = t }, lineOnly, m)
                elseif head ~= "" then
                    -- A line of text: for the next step of the block, or a note of its own.
                    local thing = word
                        and (
                            word == "trash"
                            or word == "buy"
                            or word == "use"
                            or word == "click"
                            or word == "clicknpc"
                            or word == "collect"
                            or word == "kill"
                        )
                    if thing then
                        -- Where an objective of the step comes from (the mobs dropping its item,
                        -- what to click): given to it at the end of the step, else a note.
                        local count, thingName, id = Thing(rest)
                        table.insert(
                            hints,
                            { word = word, count = count, name = thingName, id = id, only = lineOnly, m = m }
                        )
                    elseif m.gossip then
                        table.insert(tips, head)
                    else
                        table.insert(texts, (head:gsub(":%s*$", "")))
                    end
                end
            end
        end
    end
    -- The hints: on the step's objectives, else notes of their own.
    local goals = {}
    for _, s in ipairs(made) do
        if s.k == "objective" then table.insert(goals, s) end
    end
    local verbs = VERBS
    for _, h in ipairs(hints) do
        local said = verbs[h.word] .. " " .. (h.count and h.count .. " " or "") .. h.name
        if goals[1] and h.word ~= "trash" and h.word ~= "buy" then
            for _, g in ipairs(goals) do
                if h.word == "kill" and g.ic ~= "kill" then
                    g.mobs, g.mi = g.mobs or {}, g.mi or (h.id and {}) or nil
                    table.insert(g.mobs, h.name)
                    if h.id and g.mi then table.insert(g.mi, h.id) end
                else
                    table.insert(tips, said)
                end
            end
        else
            -- With the step's text before it, one note ("Destroy This Item: Hearthstone").
            local t = texts[1] and (table.concat(texts, ": ") .. ": " .. said) or said
            texts = {}
            local s = Add({ k = "note", t = t }, h.only, h.m)
            if s then s.nt = nil end
        end
    end
    -- Text with nothing after it: a note (with its NPC when the block talks to one).
    if texts[1] or (npc and not made[1]) then
        local t = texts[1] and table.concat(texts, ": ") or ("Talk to " .. npc.name)
        local step = { k = "note", t = t }
        if npc then
            step.e, step.id, step.n = "npc", npc.id, npc.name
        end
        local s = Emit(step, only)
        if s then table.insert(made, s) end
    end
    if tips[1] then
        for _, s in ipairs(made) do
            s.nt = {}
            for _, t in ipairs(tips) do
                table.insert(s.nt, { l = 2, t = t })
            end
        end
    end
end

for _, block in ipairs(blocks) do
    for _, label in ipairs(block.sticky or {}) do
        local target = labels[label] and blocks[labels[label]]
        if target then Convert(target, ALL, true) end
    end
    Convert(block, ALL, false)
end

-- Levels: the quest's level (accept, objective, turn-in), else the step before's, never going
-- down, a "ding" step its own; the addon leaves behind steps planned well below the character.
do
    local level = fromLevel
    for _, s in ipairs(steps) do
        if s.k == "grind" and s.lvl then
            level = math.max(level, s.lvl)
        elseif s.q and questLevel[s.q] then
            level = math.max(level, math.min(questLevel[s.q], toLevel))
        end
        s.lvl = s.lvl or level
    end
end

-- Writing ----------------------------------------------------------------------------------------------

local function Lua(v)
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t == "number" or t == "boolean" then return tostring(v) end
    local array, n = true, 0
    for _ in pairs(v) do
        n = n + 1
    end
    for i = 1, n do
        if v[i] == nil then array = false end
    end
    local parts = {}
    if array then
        for i = 1, n do
            parts[i] = Lua(v[i])
        end
    else
        local keys = {}
        for k in pairs(v) do
            table.insert(keys, k)
        end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            table.insert(parts, k .. " = " .. Lua(v[k]))
        end
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
end

local slug = name:gsub("%(.-%)", ""):gsub("[^%w]", "")
local path = opts.out .. "/" .. slug .. ".lua"
os.execute("mkdir -p " .. Quote(opts.out))
local out = assert(io.open(path, "w"))
out:write("-- Generated by addon/tools/zygor_convert.lua from Zygor's \"" .. guide.title .. '". Do not edit:\n')
out:write("-- convert again instead.\n")
out:write("Pathwright.Builtin.Register({\n")
out:write("    name = " .. Lua(name) .. ",\n")
out:write("    origin = " .. Lua("Zygor: " .. guide.title) .. ",\n")
out:write("    fromLevel = " .. fromLevel .. ",\n    toLevel = " .. toLevel .. ",\n")
out:write('    locale = "enUS",\n    version = 1,\n    format = 2,\n')
out:write("    created = " .. os.time() .. ",\n")
out:write("    variants = {\n")
for _, v in ipairs(variants) do
    out:write("        " .. Lua(v) .. ", -- " .. races[v.race].name .. " " .. classes[v.class] .. "\n")
end
out:write("    },\n    steps = {\n")
for _, s in ipairs(steps) do
    out:write("        " .. Lua(s) .. ",\n")
end
out:write("    },\n})\n")
out:close()

local counts = {}
for _, s in ipairs(steps) do
    counts[s.k] = (counts[s.k] or 0) + 1
end
local summary = {}
for k, n in pairs(counts) do
    table.insert(summary, k .. " " .. n)
end
table.sort(summary)
print(string.format("%s: %d steps (%s), %d variants -> %s", name, #steps, table.concat(summary, ", "), #variants, path))
if dbPath ~= opts.db then os.remove(dbPath) end
