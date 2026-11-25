-- The way on foot from where the character stands to a place, found in game on the walkable
-- ground (Terrain.lua) as the app finds its walks (crates/fg-route/src/terrain): A* from floor to
-- floor, a step 10 (14 across a corner), 15 and 21 when swum, 5 for a drop within a cell; the
-- floors tell the steep ground, the walls, the caves and the bridges.
--
-- A search starts on the floors under the character and ends on the place's, or on a point of
-- the walk the guide planned to it (a join, with the yards left from there): the cheapest of
-- them, what is left counted. Its way is then drawn straight wherever the ground between two
-- of its floors can be walked in a line (Sight).
--
-- A long search is not done in one frame: Walker:Start runs it a little every frame (BUDGET
-- milliseconds), Walker.Solve all at once (the tests, short walks).

local FG = Pathwright
local Terrain = FG.Terrain

local Walker = {}
FG.Walker = Walker

local CELL = Terrain.CELL
local STAND, SWIM, MULTI = Terrain.STAND, Terrain.SWIM, Terrain.MULTI
local DR, DC = Terrain.DR, Terrain.DC
local WALKED = { 10, 10, 10, 10, 14, 14, 14, 14 }
local SWUM = { 15, 15, 15, 15, 21, 21, 21, 21 }
local DROPPED = 5
-- The direction (1 to 8) of a step of (dr, dc), at (dr + 1) * 3 + dc + 2.
local DIRECTION = { 5, 1, 6, 3, false, 4, 7, 2, 8 }
-- A place off the floors is taken to the nearest floor within this many cells.
local SNAP = 6
-- A floor the character is not likely on (under the ground while outdoors, on it while indoors)
-- starts this much further (cost).
local UNLIKELY = 300
-- Floors explored at most, and the weight of what is left to go: 1 finds the shortest way,
-- more finds one sooner (a far place: a little longer is no matter, minutes of search are).
local LIMIT = 250000
-- The weight by how far the place is (cells): the shortest way within 1000 yards, a way up to a
-- few percent longer further, found many times sooner.
local WEIGHTS = { { 120, 1 }, { 400, 1.15 }, { math.huge, 1.4 } }
-- A straight line is looked for across this many floors of the way at most.
local LOOK = 60
-- Milliseconds of search a frame, and in a fight.
local BUDGET, BUDGET_FIGHT = 2, 0.7

local byte, floor, max, min, abs, huge = string.byte, math.floor, math.max, math.min, math.abs, math.huge
local Tile = Terrain.Tile

-- The directions of each first floor's steps: MASK_DIRS[mask] = { d, ... }.
local MASK_DIRS = {}
for mask = 0, 255 do
    local dirs = {}
    for d = 1, 8 do
        if floor(mask / 2 ^ (d - 1)) % 2 == 1 then dirs[#dirs + 1] = d end
    end
    MASK_DIRS[mask] = dirs
end
-- The floors of a record's byte: BITS[bits] = { j, ... }.
local BITS = {}
for bits = 0, 255 do
    local floors = {}
    for j = 0, 7 do
        if floor(bits / 2 ^ j) % 2 == 1 then floors[#floors + 1] = j end
    end
    BITS[bits] = floors
end

local function Node(r, c, f) return (r * 4096 + c) * 8 + f end

local function Place(node)
    local f = node % 8
    local rc = (node - f) / 8
    local c = rc % 4096
    return (rc - c) / 4096, c, f
end
Walker.Node, Walker.Place = Node, Place

--- Yards of a cost.
local function Yards(cost) return cost / 10 * CELL end

-- Floors under a point -------------------------------------------------------------------------

--- The floors that can be stood on around a world position: { { node, cost }, ... }, the cost
--- what it takes to get there from the position. The cell's own and its neighbours'; without
--- any, the nearest within SNAP cells. `likely(flags)` (optional): false for a floor to count
--- further away.
function Walker.Under(map, north, west, likely)
    local row, column = Terrain.Cell(north, west)
    local out = {}
    local function Ring(reach, inner)
        for r = row - reach, row + reach do
            for c = column - reach, column + reach do
                if max(abs(r - row), abs(c - column)) > inner then
                    local mn, mw = Terrain.Middle(r, c)
                    local cost = floor(math.sqrt((mn - north) ^ 2 + (mw - west) ^ 2) / CELL * 10 + 0.5)
                    for f = 0, Terrain.Floors(map, r, c) - 1 do
                        local flags = Terrain.Flags(map, r, c, f)
                        if flags % 2 == STAND then
                            local far = likely and not likely(flags) and UNLIKELY or 0
                            out[#out + 1] = { Node(r, c, f), cost + far }
                        end
                    end
                end
            end
        end
    end
    Ring(1, -1)
    local reach = 1
    while #out == 0 and reach < SNAP do
        reach = reach + 1
        Ring(reach, reach - 1)
    end
    return out
end

-- Passages -------------------------------------------------------------------------------------

-- A lift, an elevator, a gate the server opens: the floors do not hold them (Terrain/
-- Passages.lua, from the app's overrides). Each joins the floors of its sides: stepped from one
-- to another for the yards through the passage.
local linksOf = {}

--- The steps through the passages of `map`: { node = { { node, cost }, ... } }.
local function Links(map)
    local links = linksOf[map]
    if links then return links end
    links = {}
    for _, p in ipairs(FG.Passages or {}) do
        if p.map == map then
            for i, a in ipairs(p.sides) do
                for j, b in ipairs(p.sides) do
                    if i ~= j then
                        local yards = math.sqrt((a[2] - p.at[1]) ^ 2 + (a[3] - p.at[2]) ^ 2)
                            + math.sqrt((b[2] - p.at[1]) ^ 2 + (b[3] - p.at[2]) ^ 2)
                        local steps = links[a[1]] or {}
                        links[a[1]] = steps
                        steps[#steps + 1] = { b[1], max(10, floor(yards / CELL * 10 + 0.5)), p }
                    end
                end
            end
        end
    end
    linksOf[map] = links
    return links
end
Walker.Links = Links

-- The search -----------------------------------------------------------------------------------

--- A* from `sources` ({ node = cost }) to the cheapest of `goals` ({ node = cost left from
--- there }), the heuristic to cell (`tr`, `tc`). Returns the goal reached, the costs and the
--- floors come from (to trace the way back), the floors explored; nil when none is reached
--- (and "limit" when the search was cut short). `cap`: nothing dearer is explored.
local function Search(map, sources, goals, tr, tc, weight, limit, tick, cap)
    local cost, from, closed = {}, {}, {}
    local buckets, low, high = {}, huge, 0
    local function Push(node, f)
        local b = buckets[f]
        if not b then
            b = { n = 0 }
            buckets[f] = b
        end
        b.n = b.n + 1
        b[b.n] = node
        if f < low then low = f end
        if f > high then high = f end
    end
    local function Left(r, c)
        local dr, dc = abs(r - tr), abs(c - tc)
        return floor(weight * (10 * max(dr, dc) + 4 * min(dr, dc)))
    end
    for node, start in pairs(sources) do
        cost[node] = start
        local r, c = Place(node)
        Push(node, start + Left(r, c))
    end
    local best, reached = huge, nil
    local explored = 0
    local links = Links(map)
    -- The tile of the floor explored, and of the neighbour looked at: mostly the same.
    local tileKey, tile, otherKey, other
    while low <= high do
        local b = buckets[low]
        if not b or b.n == 0 then
            buckets[low] = nil
            low = low + 1
        elseif low >= best or (cap and low > cap) then
            break
        else
            local node = b[b.n]
            b[b.n] = nil
            b.n = b.n - 1
            if not closed[node] then
                closed[node] = true
                local here = cost[node]
                local left = goals[node]
                if left and here + left < best then
                    best, reached = here + left, node
                end
                explored = explored + 1
                if explored > limit then return reached, cost, from, explored, "limit" end
                if explored % 64 == 0 and tick then tick() end
                local r, c, f = Place(node)
                local key = floor(r / 64) * 64 + floor(c / 64)
                if key ~= tileKey then
                    tileKey, tile = key, Tile(map, floor(r / 64), floor(c / 64))
                end
                local cell = (r % 64) * 64 + c % 64
                local record
                if f == 0 then
                    local full = tile.full[cell]
                    record = full and tile.records + full * 9
                else
                    record = tile.extraRecords + (tile.base[cell] + f - 1) * 9
                end
                -- A step to floor `j` of the neighbour in direction `d` (9: this cell).
                local function Step(d, j)
                    local nr, nc = r, c
                    if d < 9 then
                        nr, nc = r + DR[d], c + DC[d]
                    end
                    if nr < 0 or nc < 0 then return end
                    local nkey = floor(nr / 64) * 64 + floor(nc / 64)
                    local t
                    if nkey == tileKey then
                        t = tile
                    else
                        if nkey ~= otherKey then
                            otherKey, other = nkey, Tile(map, floor(nr / 64), floor(nc / 64))
                        end
                        t = other
                    end
                    if not t then return end
                    local ncell = (nr % 64) * 64 + nc % 64
                    local flags
                    if j == 0 then
                        flags = byte(t.flags, ncell + 1)
                    else
                        local count = t.count[ncell]
                        if not count or j >= count then return end
                        flags = byte(t.data, t.extraFlags + t.base[ncell] + j)
                    end
                    if flags % 2 ~= STAND then return end
                    local next = (nr * 4096 + nc) * 8 + j
                    if closed[next] then return end
                    local step = d == 9 and DROPPED or (flags % 4 >= SWIM and SWUM[d] or WALKED[d])
                    local there = here + step
                    local known = cost[next]
                    if not known or there < known then
                        cost[next], from[next] = there, node
                        Push(next, there + Left(nr, nc))
                    end
                end
                if not record then
                    local dirs = MASK_DIRS[byte(tile.masks, cell + 1)]
                    for i = 1, #dirs do
                        Step(dirs[i], 0)
                    end
                else
                    local data = tile.data
                    for d = 1, 9 do
                        local bits = byte(data, record + d)
                        if bits ~= 0 then
                            local floors = BITS[bits]
                            for i = 1, #floors do
                                Step(d, floors[i])
                            end
                        end
                    end
                end
                -- Through a passage, to its other sides.
                local through = links[node]
                if through then
                    for i = 1, #through do
                        local next, there = through[i][1], here + through[i][2]
                        if not closed[next] and (not cost[next] or there < cost[next]) then
                            cost[next], from[next] = there, node
                            local nr, nc = Place(next)
                            Push(next, there + Left(nr, nc))
                        end
                    end
                end
            end
        end
    end
    return reached, cost, from, explored
end

-- A straight line --------------------------------------------------------------------------------

--- Whether the ground from floor `a` to floor `b` (nodes) is walked in a straight line: every
--- cell the line crosses is stepped to from the one before, floor to floor, and none is swum
--- unless `wet`.
function Walker.Sight(map, a, b, wet)
    local ar, ac, af = Place(a)
    local br, bc, bf = Place(b)
    local dr, dc = br - ar, bc - ac
    local steps = max(abs(dr), abs(dc)) * 2
    if steps == 0 then return af == bf end
    local r, c, f = ar, ac, af
    for i = 1, steps do
        local t = i / steps
        local nr, nc = floor(ar + 0.5 + dr * t), floor(ac + 0.5 + dc * t)
        if nr ~= r or nc ~= c then
            local d = DIRECTION[(nr - r + 1) * 3 + nc - c + 2]
            local floors = BITS[Terrain.Steps(map, r, c, f, d)]
            local to
            for k = 1, #floors do
                local flags = Terrain.Flags(map, nr, nc, floors[k])
                if flags % 2 == STAND and (wet or flags % 4 < SWIM) then
                    to = floors[k]
                    -- The floor the line ends on, when it is among them.
                    if not (nr == br and nc == bc) or to == bf then break end
                end
            end
            if not to then return false end
            r, c, f = nr, nc, to
        end
    end
    return r == br and c == bc and f == bf
end

--- The floors of a way where it turns: the fewest, each seen from the one before.
local function Turns(map, nodes, tick)
    local kept = { nodes[1] }
    local i, n = 1, #nodes
    while i < n do
        local a = nodes[i]
        local wet = Terrain.Flags(map, Place(a)) % 4 >= SWIM
        local far, missed = i + 1, 0
        for j = i + 2, min(n, i + LOOK) do
            local b = nodes[j]
            if Walker.Sight(map, a, b, wet or Terrain.Flags(map, Place(b)) % 4 >= SWIM) then
                far, missed = j, 0
            else
                missed = missed + 1
                if missed > 4 then break end
            end
        end
        kept[#kept + 1] = nodes[far]
        i = far
        if tick then tick() end
    end
    return kept
end

-- The floor of a place -------------------------------------------------------------------------

-- A place is known by where it is on the map, not by its height: where the ground has several
-- floors (a cave under a hill, a bridge, a city's tiers) it could be on any. The walk the guide
-- planned to it tells: the app knew the floor, and its walk from the last point on plain ground
-- has a length that only the way to the right floor has. The floors found, by place: a search
-- each, not done again.
local floorOf, floorsKnown = {}, 0

--- Of `under` (the floors under the place, as Walker.Under gives them), the one the planned
--- walk leads to: its entry, or nil when the joins do not tell.
local function FloorOf(map, target, under, joins, tick)
    local key = map .. ":" .. target[1] .. ":" .. target[2] .. ":" .. #joins
    local known = floorOf[key]
    if known ~= nil then return known or nil end
    -- The join nearest the place along the walk, on ground of one floor.
    local last
    for _, join in ipairs(joins) do
        local r, c = Terrain.Cell(join[1], join[2])
        if join.left > CELL and Terrain.Floors(map, r, c) == 1 and Terrain.Flags(map, r, c, 0) % 2 == STAND then
            if not last or join.left < last.left then last = join end
        end
    end
    local found = false
    if last then
        local r, c = Terrain.Cell(last[1], last[2])
        local tr, tc = Terrain.Cell(target[1], target[2])
        local left = last.left / CELL * 10
        local _, cost = Search(map, { [Node(r, c, 0)] = 0 }, {}, tr, tc, 1, 40000, tick, left * 1.4 + 100)
        local gap
        for _, s in ipairs(under) do
            local there = cost[s[1]]
            if there and (not gap or abs(there + s[2] - left) < gap) then
                found, gap = s, abs(there + s[2] - left)
            end
        end
    end
    if floorsKnown >= 60 then
        floorOf, floorsKnown = {}, 0
    end
    floorOf[key], floorsKnown = found, floorsKnown + 1
    return found or nil
end

-- A walk -----------------------------------------------------------------------------------------

--- The way on foot for `request`:
---   map, north, west   where the character stands (a continent, world yards);
---   indoors            true inside (a cave, a building), false outside, nil unknown;
---   target             { north, west }: the place;
---   joins              (optional) points of a walk planned to the place: { { north, west,
---                      left = yards from there to the place, ... }, ... }.
--- Returns { points = { { north, west }, ... } (from the character to the place or the join),
--- yards (of it), join (the join it ends on, nil: the place), explored }; or nil and why
--- ("nodata": the ground is not known there, "offmesh": no floor under one end, "unreachable",
--- "limit").
function Walker.Solve(request, tick)
    local map, target = request.map, request.target
    if not Terrain.Has(map) then return nil, "nodata" end
    local likely
    if request.indoors ~= nil then
        local under = Terrain.KIND_UNDER
        likely = function(flags)
            if flags % 16 < MULTI then return true end
            local below = floor(flags / under) % 2 == 1
            return below == request.indoors
        end
    end
    local sources = {}
    for _, s in ipairs(Walker.Under(map, request.north, request.west, likely)) do
        if not sources[s[1]] or s[2] < sources[s[1]] then sources[s[1]] = s[2] end
    end
    if not next(sources) then return nil, "offmesh" end
    local goals, joinOf = {}, {}
    local under = Walker.Under(map, target[1], target[2])
    -- Where the ground under the place has several floors: the one the planned walk leads to.
    if request.joins and #request.joins > 0 then
        for _, s in ipairs(under) do
            local r, c = Place(s[1])
            if Terrain.Floors(map, r, c) > 1 then
                local one = FloorOf(map, target, under, request.joins, tick)
                if one then under = { one } end
                break
            end
        end
    end
    for _, s in ipairs(under) do
        if not goals[s[1]] or s[2] < goals[s[1]] then goals[s[1]] = s[2] end
    end
    local hasTarget = next(goals) ~= nil
    -- A join only where the ground has one floor: on which of several it runs is not known.
    for _, join in ipairs(request.joins or {}) do
        local r, c = Terrain.Cell(join[1], join[2])
        if Terrain.Floors(map, r, c) == 1 and Terrain.Flags(map, r, c, 0) % 2 == STAND then
            local node, left = Node(r, c, 0), floor(join.left / CELL * 10 + 0.5)
            if not goals[node] or left < goals[node] then
                goals[node], joinOf[node] = left, join
            end
        end
    end
    if not next(goals) then return nil, "offmesh" end
    local tr, tc = Terrain.Cell(target[1], target[2])
    local sr, sc = Terrain.Cell(request.north, request.west)
    local apart = max(abs(sr - tr), abs(sc - tc))
    local weight = request.weight
    for _, w in ipairs(WEIGHTS) do
        if weight then break end
        if apart <= w[1] then weight = w[2] end
    end
    local reached, cost, from, explored, why = Search(map, sources, goals, tr, tc, weight, request.limit or LIMIT, tick)
    if not reached then return nil, why or (hasTarget and "unreachable" or "offmesh"), explored end
    -- The way back from the goal to the floor it started on.
    local back, node = {}, reached
    while node do
        back[#back + 1] = node
        node = from[node]
    end
    local nodes = {}
    for i = #back, 1, -1 do
        nodes[#nodes + 1] = back[i]
    end
    local turns = Turns(map, nodes, tick)
    local points = { { request.north, request.west } }
    for i = 1, #turns do
        local r, c = Place(turns[i])
        local n, w = Terrain.Middle(r, c)
        -- The first floor is under the character, the last under the place: the line goes from
        -- one to the other, not through the middle of their cells.
        if i > 1 and i < #turns then points[#points + 1] = { n, w } end
    end
    local join = joinOf[reached]
    if join then
        points[#points + 1] = { join[1], join[2] }
    else
        points[#points + 1] = { target[1], target[2] }
    end
    return {
        points = points,
        yards = Yards(cost[reached]),
        join = join,
        explored = explored,
        floors = #nodes,
    }
end

-- A little every frame ---------------------------------------------------------------------------

local jobs, pump = {}, nil
local clock = debugprofilestop

local function Run()
    local job = jobs[1]
    while job and job.cancelled do
        table.remove(jobs, 1)
        job = jobs[1]
    end
    if not job then
        if pump then pump:Hide() end
        return
    end
    local budget = InCombatLockdown and InCombatLockdown() and BUDGET_FIGHT or BUDGET
    job.since = clock and clock() or 0
    job.budget = budget
    local ok, route, why = coroutine.resume(job.thread)
    if coroutine.status(job.thread) == "dead" then
        table.remove(jobs, 1)
        if not job.cancelled then
            if not ok then
                FG:Error("walker", route)
                route, why = nil, "error"
            end
            job.done(route, why)
        end
    end
end

--- Find the way for `request` (see Solve) a little every frame, then call `done(route, why)`.
--- Returns the job, to cancel it (Walker:Cancel).
function Walker:Start(request, done)
    local job = { done = done }
    local function tick()
        if clock and clock() - job.since >= job.budget then coroutine.yield() end
    end
    job.thread = coroutine.create(function() return Walker.Solve(request, tick) end)
    jobs[#jobs + 1] = job
    if not pump and CreateFrame then
        pump = CreateFrame("Frame")
        pump:SetScript("OnUpdate", function() Run() end)
    end
    if pump then pump:Show() end
    return job
end

--- Give a job up: its `done` is not called.
function Walker:Cancel(job)
    if job then job.cancelled = true end
end

--- Run what is waiting to its end (the tests).
function Walker:Finish()
    clock = nil
    while jobs[1] do
        Run()
    end
    clock = debugprofilestop
end
