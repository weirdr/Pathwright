-- The fastest way across the world to the place the guide points at, when it is more than a
-- walk (`pathJourney`): on foot, by the flight paths the character knows, by boat, zeppelin, tram
-- and portal (TravelData.lua, from the app's travel data), and with the hearthstone. It is found
-- again as the character moves, so it always starts from where the character stands.
--
-- A journey is a list of stops, each a thing to do at a place: fly from this flight master, take
-- this zeppelin, use the hearthstone. The guide's pathing (Pathing.lua) leads to the first of
-- them as it leads to a step: the way on foot found on the walkable ground (Walker.lua), the
-- compass and the arrow.
--
-- The time of a walk is first guessed from its straight line. The walks of the journey chosen
-- are then found on the ground (Walker.lua, a little every frame), and the journey is planned
-- again with what they really take: a walk that turns out long, or that the ground does not
-- allow, gives way to another journey.
--
-- Flight paths are only known from a flight master's map: those the profile addon has seen
-- (`flights` of the character's profile). The hearthstone's place: where the character bound it
-- or last arrived with it, else the inn its name says (TravelData.inns).

local FG = Pathwright
local T = FG.T

local Journey = {}
FG.Journey = Journey

local L = {
    fly = T("Fly to %s"),
    hearth = T("Use your hearthstone (%s)"),
    hearthSoon = T("Use your hearthstone (%s) in %d s"),
    walk = T("walk"),
}

-- A walk guessed from its straight line is this much longer; one the ground's search gave up on
-- (too far to tell) this much.
local WIGGLE, FAR = 1.25, 2.5
-- Seconds a flight costs besides the air (the flight master, taking off, landing), and the
-- hearthstone (its cast, the loading screen). A hearthstone ready within SOON seconds counts.
local BOARD, CAST, SOON = 30, 15, 120
-- The stop being gone to is kept unless another journey is this much faster (no going back and
-- forth between two that take about as long).
local KEEP = 0.85
-- Planned again when the character has moved MOVED yards, or AGAIN seconds have gone by. What
-- the ground said of a walk from where the character stood holds within NEAR yards of there.
local MOVED, AGAIN, NEAR = 40, 5, 120
-- A walk shorter than this is not looked for on the ground (the guess is good enough).
local SHORT = 60
local HEARTHSTONE, HEARTH_SPELL = 6948, 8690

local floor, sqrt, huge = math.floor, math.sqrt, math.huge

local function Key(continent, north, west) return continent .. ":" .. floor(north + 0.5) .. ":" .. floor(west + 0.5) end
Journey.Key = Key

local function Apart(a, b) return sqrt((a.north - b.north) ^ 2 + (a.west - b.west) ^ 2) end

-- The plan --------------------------------------------------------------------------------------

--- The fastest journey from `from` to `to` ({ continent, north, west, key (optional: the one its
--- walk is measured under) }) for `who`:
---   faction ("H", "A"), speed (yards a second on foot), flights ({ [flight point] = true }),
---   hearth ({ continent, north, west, name, wait (seconds until it is ready) } or nil),
---   quest (function(id, held): whether the link that quest opens is open; nil: none is),
---   measured ({ ["from>to"] = { yards = n } | { blocked = true } | { far = true } }: what the
---   ground said of a walk, the keys of its ends; "start" for `from`),
---   keep (the key of the stop being gone to, favoured).
--- Returns { seconds, stops = { { kind ("fly", "link", "hearth"), text, key, continent, north,
--- west (where it is done; none for the hearthstone), to = { continent, north, west, name, id
--- (a flight's: the flight point flown to) } },
--- ... } (none: a walk), walks = { { from = node, to = node }, ... } (its walks, to look for on
--- the ground) }; nil when nothing leads there.
function Journey.Plan(from, to, who)
    local data = FG.TravelData
    if not data then return nil end
    local speeds = data.speeds
    local nodes = {}
    local function Add(continent, north, west, key)
        local node = { continent = continent, north = north, west = west, out = {} }
        node.key = key or Key(continent, north, west)
        nodes[#nodes + 1] = node
        return node
    end
    local start = Add(from.continent, from.north, from.west, "start")
    local goal = Add(to.continent, to.north, to.west, to.key)

    -- Boats, zeppelins, trams, portals.
    for _, link in ipairs(data.links) do
        local open = not link[2] or link[2] == who.faction
        if open and link[12] then open = who.quest ~= nil and who.quest(link[12], link[13]) == true end
        if open then
            local a, b = Add(link[3], link[4], link[5]), Add(link[6], link[7], link[8])
            local cost = link[9] + (link[11] and 0 or speeds.wait)
            a.out[#a.out + 1] = { to = b, cost = cost, kind = "link", name = link[1] }
            if not link[10] then b.out[#b.out + 1] = { to = a, cost = cost, kind = "link", name = link[1] } end
        end
    end

    -- The flight paths between the points the character knows: a node on the ground each (the
    -- flight master), one taking off there and one flown to, which alone lands (boarding is not
    -- a way to stand where one stood).
    local off, landing = {}, {}
    for id in pairs(who.flights or {}) do
        local point = data.nodes[id]
        if point and (not point[5] or point[5] == who.faction) then
            local ground = Add(point[2], point[3], point[4])
            local up = { air = true, id = id, name = point[1], out = {}, ground = ground }
            local down = { air = true, id = id, name = point[1], out = {}, ground = ground }
            nodes[#nodes + 1] = up
            nodes[#nodes + 1] = down
            off[id], landing[id] = up, down
            ground.out[#ground.out + 1] = { to = up, cost = BOARD, kind = "board" }
            down.out[#down.out + 1] = { to = ground, cost = 0, kind = "land" }
        end
    end
    for _, flight in ipairs(data.flights) do
        local to = landing[flight[2]]
        if to and off[flight[1]] then
            local seconds = flight[3] / speeds.flight
            local up, through = off[flight[1]], landing[flight[1]]
            up.out[#up.out + 1] = { to = to, cost = seconds, kind = "fly" }
            through.out[#through.out + 1] = { to = to, cost = seconds, kind = "fly" }
        end
    end

    -- The hearthstone, from where the character stands only.
    local hearth = who.hearth
    if hearth and (hearth.wait or 0) <= SOON then
        local home = Add(hearth.continent, hearth.north, hearth.west)
        local cost = CAST + (hearth.wait or 0)
        if who.keep == "hearth" then cost = cost * KEEP end
        start.out[#start.out + 1] = { to = home, cost = cost, kind = "hearth", name = hearth.name, wait = hearth.wait }
    end

    -- A walk between two places of a continent: what the ground said, else its straight line.
    local measured = who.measured or {}
    local function Walk(a, b)
        local known = measured[a.key .. ">" .. b.key]
        local straight = Apart(a, b)
        local seconds
        if known and known.blocked then
            return nil
        elseif known and known.yards then
            seconds = known.yards / who.speed
        else
            seconds = straight * (known and known.far and FAR or WIGGLE) / who.speed
        end
        if a == start and b.key == who.keep then seconds = seconds * KEEP end
        return seconds
    end

    -- Dijkstra over the few dozen nodes, each reached on foot (1) or otherwise (2): a walk does
    -- not go on as another walk (it would be one walk, counted as the ground has it), only from
    -- where the character stands or gets off.
    local cost, back, done = { {}, {} }, { {}, {} }, { {}, {} }
    cost[2][start] = 0
    local arrived
    while true do
        local at, mode, least = nil, nil, huge
        for m = 1, 2 do
            for _, node in ipairs(nodes) do
                local c = cost[m][node]
                if c and not done[m][node] and c < least then
                    at, mode, least = node, m, c
                end
            end
        end
        if not at then break end
        if at == goal then
            arrived = mode
            break
        end
        done[mode][at] = true
        local function Reach(node, m, seconds, edge)
            if not done[m][node] and (not cost[m][node] or least + seconds < cost[m][node]) then
                cost[m][node] = least + seconds
                back[m][node] = { from = at, mode = mode, edge = edge }
            end
        end
        for _, edge in ipairs(at.out) do
            Reach(edge.to, 2, edge.cost, edge)
        end
        if mode == 2 and not at.air then
            for _, node in ipairs(nodes) do
                if node ~= at and not node.air and node ~= start and node.continent == at.continent then
                    local seconds = Walk(at, node)
                    if seconds then Reach(node, 1, seconds, nil) end
                end
            end
        end
    end
    if not arrived then return nil end

    -- From the goal back to the start, then its stops in order.
    local steps = {}
    local node, mode = goal, arrived
    while node ~= start do
        local step = back[mode][node]
        table.insert(steps, 1, { from = step.from, to = node, edge = step.edge })
        node, mode = step.from, step.mode
    end
    local plan = { seconds = cost[arrived][goal], stops = {}, walks = {} }
    local flying
    for _, step in ipairs(steps) do
        local edge, at = step.edge, step.from
        if not edge then
            plan.walks[#plan.walks + 1] = { from = step.from, to = step.to }
        elseif edge.kind == "link" then
            plan.stops[#plan.stops + 1] = {
                kind = "link",
                text = edge.name,
                key = at.key,
                continent = at.continent,
                north = at.north,
                west = at.west,
                to = { continent = step.to.continent, north = step.to.north, west = step.to.west },
            }
        elseif edge.kind == "hearth" then
            local text = (edge.wait or 0) > 0 and string.format(L.hearthSoon, edge.name, math.ceil(edge.wait))
                or string.format(L.hearth, edge.name)
            plan.stops[#plan.stops + 1] = {
                kind = "hearth",
                text = text,
                key = "hearth",
                to = { continent = step.to.continent, north = step.to.north, west = step.to.west, name = edge.name },
            }
        elseif edge.kind == "board" then
            flying = { kind = "fly", key = at.key, continent = at.continent, north = at.north, west = at.west }
            plan.stops[#plan.stops + 1] = flying
        elseif edge.kind == "fly" and flying then
            local ground = step.to.ground
            flying.text = string.format(L.fly, step.to.name)
            flying.to = {
                continent = ground.continent,
                north = ground.north,
                west = ground.west,
                name = step.to.name,
                id = step.to.id,
            }
        end
    end
    return plan
end

--- What a journey says in a line: its stops, then the walk.
function Journey.Text(plan)
    local parts = {}
    for _, stop in ipairs(plan.stops) do
        parts[#parts + 1] = stop.text
    end
    parts[#parts + 1] = L.walk
    return table.concat(parts, " > ")
end

-- The character ---------------------------------------------------------------------------------

local function Profile()
    return PathwrightDB and PathwrightDB.profiles and FG.CharacterKey and PathwrightDB.profiles[FG:CharacterKey()]
        or nil
end

local function Faction()
    local group = UnitFactionGroup and FG.Readable(UnitFactionGroup("player"))
    return group == "Horde" and "H" or group == "Alliance" and "A" or nil
end

-- Where the hearthstone was seen to take the character, by the place it names (kept with the
-- profile).
local function Arrivals()
    local profile = Profile()
    if not profile then return {} end
    profile.hearths = profile.hearths or {}
    return profile.hearths
end

--- The hearthstone: { continent, north, west, name, wait }; nil without one, or when its place
--- is not known.
function Journey.Hearth()
    local name = GetBindLocation and FG.Readable(GetBindLocation())
    if type(name) ~= "string" or name == "" then return nil end
    local count = GetItemCount and tonumber(FG.Readable(GetItemCount(HEARTHSTONE))) or 0
    if count < 1 then return nil end
    local wait = 0
    local cooldown = C_Container and C_Container.GetItemCooldown or GetItemCooldown
    if cooldown then
        local ok, began, lasts = pcall(cooldown, HEARTHSTONE)
        began, lasts = ok and tonumber(FG.Readable(began)), ok and tonumber(FG.Readable(lasts))
        if began and lasts and lasts > 0 then wait = math.max(0, began + lasts - (GetTime and GetTime() or 0)) end
    end
    local profile = Profile()
    local bind = profile and profile.bind
    local continent, north, west
    -- Where the character stood when it bound it there.
    if bind and bind.name == name and bind.position and FG.Compass then
        continent, north, west = FG.Compass.World(bind.position.map, bind.position.x / 100, bind.position.y / 100)
    end
    -- Where it last took the character.
    local seen = Arrivals()[name]
    if not continent and seen then
        continent, north, west = seen[1], seen[2], seen[3]
    end
    -- The inn of that name.
    if not continent and FG.TravelData then
        local areas = {}
        for _, id in ipairs(bind and bind.name == name and bind.areas or {}) do
            areas[id] = true
        end
        for _, inn in ipairs(FG.TravelData.inns) do
            local same = inn[1] == name
            for _, id in ipairs(inn[2]) do
                same = same or areas[id] == true
            end
            if same then
                continent, north, west = inn[3], inn[4], inn[5]
                break
            end
        end
    end
    if not continent then return nil end
    return { continent = continent, north = north, west = west, name = name, wait = wait }
end

--- Who travels: what Journey.Plan asks of the character (the walks' measures apart).
function Journey.Who()
    local speeds = FG.TravelData.speeds
    local level = UnitLevel and tonumber(FG.Readable(UnitLevel("player"))) or 1
    local profile = Profile()
    local log = C_QuestLog and C_QuestLog.IsOnQuest
    local flagged = C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted
    return {
        faction = Faction(),
        speed = speeds.run * (level >= speeds.mountLevel and 1 + speeds.mount or 1),
        flights = profile and profile.flights or {},
        hearth = Journey.Hearth(),
        quest = function(id, held)
            local on = log and FG.Readable(log(id)) == true
            if held then return on end
            return on or (flagged and FG.Readable(flagged(id)) == true) or false
        end,
    }
end

-- The journey being made ------------------------------------------------------------------------

-- { key (the place's), plan, stop (its first), at = { continent, north, west } (planned from),
-- time, dirty (planned again at the next look), first = { at, [key] = measure } (the walks from
-- where the character stands), flying (the stop shown in the air) }.
local state = {}
-- What the ground said of the walks between two places that do not move: { ["from>to"] = ... }.
local measured = {}
-- The walk being looked for on the ground: { key, job }.
local looking
-- The hearthstone was just used at { continent, north, west }: where it lands is its place.
local hearthed

--- Forget the journey (the place changed by hand, the tests).
function Journey:Forget()
    state = {}
    if looking and FG.Walker then FG.Walker:Cancel(looking.job) end
    looking = nil
end

--- Forget what the ground said too (the tests).
function Journey:Reset()
    self:Forget()
    measured, hearthed = {}, nil
end

local function Measure(route, why)
    if route then return { yards = route.yards + (route.join and route.join.left or 0) } end
    if why == "unreachable" then return { blocked = true } end
    if why == "limit" then return { far = true } end
    return { unknown = true }
end

--- The way on foot from (`north`, `west`) of `continent` to the stop or place of key `key` was
--- looked for on the ground (Pathing.lua's, the one shown): `route` (nil: none, and `why`).
function Journey:Walked(continent, north, west, key, route, why)
    if not key then return end
    local first = state.first
    local at = { continent = continent, north = north, west = west }
    if not first or first.at.continent ~= continent or Apart(first.at, at) > NEAR then
        first = { at = at }
        state.first = first
    end
    local measure = Measure(route, why)
    local before = first[key]
    first[key] = measure
    -- Planned again when it changes what was known.
    if
        not before
        or before.blocked ~= measure.blocked
        or before.far ~= measure.far
        or math.abs((before.yards or 0) - (measure.yards or 0)) > 50
    then
        state.dirty = true
    end
end

-- Look on the ground for the first walk of the plan not known yet (the one from where the
-- character stands is Pathing.lua's: Journey:Walked).
local function Look(plan)
    if looking or not FG.Walker or not FG.Terrain then return end
    for _, walk in ipairs(plan.walks) do
        local a, b = walk.from, walk.to
        local key = a.key .. ">" .. b.key
        if a.key ~= "start" and not measured[key] then
            if Apart(a, b) < SHORT or not FG.Terrain.Has(a.continent) then
                measured[key] = { unknown = true }
            else
                looking = { key = key }
                looking.job = FG.Walker:Start(
                    { map = a.continent, north = a.north, west = a.west, target = { b.north, b.west } },
                    function(route, why)
                        measured[key] = Measure(route, why)
                        looking = nil
                        state.dirty = true
                    end,
                    true
                )
                return
            end
        end
    end
end

-- The hearthstone's place is where it takes the character: kept by the name it has.
local function Landed(continent, north, west)
    if not hearthed then return end
    local now = GetTime and GetTime() or 0
    if now - hearthed.time > 60 or now < hearthed.time then
        hearthed = nil
        return
    end
    local here = { continent = continent, north = north, west = west }
    if hearthed.continent == continent and Apart(hearthed, here) < 100 then return end
    local name = GetBindLocation and FG.Readable(GetBindLocation())
    if type(name) == "string" and name ~= "" then Arrivals()[name] = { continent, floor(north), floor(west) } end
    hearthed = nil
end

--- The next stop of the journey to `place` ({ continent, north, west, key }) for a character at
--- (`north`, `west`) of `continent`; nil when the way is a walk (or nothing leads there).
function Journey:Update(continent, north, west, place)
    if not FG.TravelData then return nil end
    Landed(continent, north, west)
    local now = GetTime and GetTime() or 0
    if state.key ~= place.key then
        self:Forget()
        state = { key = place.key }
    end
    -- In the air: the flight taken, no place to go to.
    if UnitOnTaxi and FG.Readable(UnitOnTaxi("player")) == true then
        state.time = nil
        return state.flying
    end
    local here = { continent = continent, north = north, west = west }
    local moved = not state.at or state.at.continent ~= continent or Apart(state.at, here) > MOVED
    if not (moved or state.dirty or not state.time or now - state.time > AGAIN or now < state.time) then
        return state.stop
    end
    state.at, state.time, state.dirty = here, now, nil
    local who = Journey.Who()
    -- The walks known: between places, and from where the character stands (while close to
    -- where they were looked for from).
    local known = setmetatable({}, { __index = measured })
    local first = state.first
    if first and (first.at.continent ~= continent or Apart(first.at, here) > NEAR) then
        first, state.first = nil, nil
    end
    if first then
        for key, measure in pairs(first) do
            if key ~= "at" then known["start>" .. key] = measure end
        end
    end
    who.measured = known
    who.keep = state.stop and state.stop.key or nil
    local plan = Journey.Plan(here, place, who)
    state.plan = plan
    state.stop = plan and plan.stops[1] or nil
    local stop = state.stop
    state.flying = stop
            and stop.kind == "fly"
            and { kind = "fly", text = stop.text, key = stop.key .. ":air", to = stop.to }
        or nil
    if plan then Look(plan) end
    return stop
end

--- The journey being made: { seconds, stops, walks }; nil without one.
function Journey:Current() return state.plan end

FG:On("UNIT_SPELLCAST_SUCCEEDED", function(unit, _, spell)
    if unit ~= "player" or FG.Readable(spell) ~= HEARTH_SPELL then return end
    local map, x, y = FG.PlayerPosition()
    if not x then return end
    local continent, north, west = FG.Compass.World(map, x / 100, y / 100)
    if continent then
        hearthed = { continent = continent, north = north, west = west, time = GetTime and GetTime() or 0 }
    end
end)
