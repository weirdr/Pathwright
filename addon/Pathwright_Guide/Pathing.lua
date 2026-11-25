-- How the guide takes the character to the place it points at, besides the compass's straight
-- line:
--   the way on foot from where the character stands, found in game on the walkable ground
--   (Walker.lua, `pathLive`): around the steep ground, over the bridges, through the caves and
--   the lifts; found again when the character leaves it. It joins the walk the guide planned
--   where that is shorter than going on alone;
--   the walk the guide planned to the step (`wp`: where it starts, then where it turns around
--   the steep ground, world coordinates), shown on the compass as the way to go while the
--   character is close to it (`pathMode`): until the way from here is found, and where the
--   ground is not known;
--   on WoW Forever, Shortest Path Forever when it is loaded (`spfLink`): it gets the place and
--   plans the way there (flights, boats, the walk), drawn with its own lines and the game's
--   waypoint (ours is left to it); the compass and the arrow then show its way, the next point
--   it leads to (Pathing:Aim), instead of the guide's walk. A journey the player replaces or
--   clears there is not sent again until the place changes or is picked again on the compass.

local FG = Pathwright

local Pathing = {}
FG.Pathing = Pathing

local OWNER = "Pathwright"
-- On the walk closer than this (yards); off it beyond REJOIN, where it is not shown any more.
-- The compass points AHEAD yards further along the walk than its point closest to the character.
local CORRIDOR, REJOIN, AHEAD = 45, 220, 30
-- Objective areas: Shortest Path Forever stays on them (held) and stops guiding inside this many
-- yards.
local AREA = 50
-- Its stop kinds, for the guide's step kinds and the compass's places.
local KINDS = {
    accept = "pickup",
    turnin = "turnin",
    objective = "objective",
    grind = "objective",
    train = "trainer",
    bind = "innkeeper",
    hearth = "innkeeper",
    flight_master = "flightmaster",
    fly = "flightmaster",
    dungeon = "dungeon",
    class = "trainer",
    profession = "trainer",
    flight = "flightmaster",
    inn = "innkeeper",
}

local function API()
    local spf = ShortestPathForever
    local api = type(spf) == "table" and spf.API
    if type(api) == "table" and type(api.NavigateRoute) == "function" then return api end
    return nil
end

--- Whether Shortest Path Forever is loaded and the setting sends it the guide's places.
function Pathing:SpfLinked() return FG:Get("spfLink") == true and API() ~= nil end

--- Whether the compass shows the guide's walk ("auto": unless Shortest Path Forever guides).
function Pathing:PathShown()
    local mode = FG:Get("pathMode")
    if mode == "on" then return true end
    if mode == "off" then return false end
    return not self:Guiding()
end

-- The walk ---------------------------------------------------------------------------------

-- { continent, points = { { north, west }, ..., the place } } (the place alone when the walk
-- goes straight), the place it leads to, and the leg reached (only goes on: a walk going back on
-- itself is not pointed backwards). `walk` is the way shown: the one found from where the
-- character stands (`walk.live`), else `planned`, the guide's.
local walk, walkPlace, reached
local planned, plannedWp

-- The way from here: found again when the character is more than OFF yards off it (at most
-- every AGAIN seconds); after a search that found none, when the character has moved MOVED
-- yards or RETRY seconds have gone by. No search within SHORT yards of the place, and the
-- planned walk is joined at points every JOIN_EVERY yards of it (JOINS at most).
local OFF, AGAIN, MOVED, RETRY, SHORT = 22, 1.5, 60, 20, 30
local JOIN_EVERY, JOINS = 33, 300
local LIVE_EVERY = 0.25
-- { key (the place's), state ("found", "failed"; nil: not looked for), why, job, at = { north,
-- west } (where it was looked for from), time, checked, yards, explored }.
local live = {}

local function Key(place) return place.m .. ":" .. place.x .. ":" .. place.y end

local function ForgetLive()
    if live.job and FG.Walker then FG.Walker:Cancel(live.job) end
    live = {}
end

--- The closest point of the leg from `a` to `b` to (`n`, `w`), and how far it is.
local function Project(a, b, n, w)
    local dn, dw = b[1] - a[1], b[2] - a[2]
    local length = dn * dn + dw * dw
    local t = length > 0 and math.max(0, math.min(1, ((n - a[1]) * dn + (w - a[2]) * dw) / length)) or 0
    local qn, qw = a[1] + t * dn, a[2] + t * dw
    return qn, qw, math.sqrt((n - qn) ^ 2 + (w - qw) ^ 2)
end

--- The walk to `place`: the step's planned one when the place is the step's own, else straight.
local function SetWalk(place, step)
    -- The same place with the same planned walk (the guide drawn again gives some places anew,
    -- a detour's): nothing changes, the way found is kept.
    local wp = step and place == step and step.wp or nil
    local same = walkPlace == place
        or (walkPlace and place and walkPlace.m and place.m and place.x and Key(walkPlace) == Key(place))
    if same and wp == plannedWp then
        walkPlace = place
        return
    end
    walk, walkPlace, reached, planned, plannedWp = nil, place, 1, nil, wp
    ForgetLive()
    if not place or not place.m or not place.x then return end
    local continent, north, west = FG.Compass.World(place.m, place.x / 100, place.y / 100)
    if not continent then return end
    local points = {}
    if step and place == step and step.wp and #step.wp >= 2 then
        for i = 1, #step.wp - 1, 2 do
            points[#points + 1] = { step.wp[i], step.wp[i + 1] }
        end
    end
    points[#points + 1] = { north, west }
    walk = { continent = continent, points = points }
    planned = walk
end

--- The leg of the walk closest to (`north`, `west`) from the one reached on, the closest point on
--- it and how far it is; nil when the walk goes straight.
local function Closest(north, west)
    local points = walk.points
    local best, bestDistance, bestN, bestW
    for k = reached, #points - 1 do
        local qn, qw, d = Project(points[k], points[k + 1], north, west)
        if not bestDistance or d < bestDistance then
            best, bestDistance, bestN, bestW = k, d, qn, qw
        end
    end
    return best, bestDistance, bestN, bestW
end

-- The way from here ------------------------------------------------------------------------

--- Whether the way is looked for from where the character stands: the setting, the ground
--- known, and the way shown at all (not while Shortest Path Forever guides).
function Pathing:LiveWanted(continent)
    return FG:Get("pathLive") == true
        and FG.Walker ~= nil
        and FG.Terrain ~= nil
        and FG.Terrain.Has(continent)
        and self:PathShown()
end

--- Points of the planned walk to join: { north, west, left = yards from there to the place,
--- leg = the leg it is on }, every JOIN_EVERY yards.
local function Joins()
    local points = planned.points
    local lengths, total = {}, 0
    for k = 1, #points - 1 do
        lengths[k] = math.sqrt((points[k + 1][1] - points[k][1]) ^ 2 + (points[k + 1][2] - points[k][2]) ^ 2)
        total = total + lengths[k]
    end
    local every = math.max(JOIN_EVERY, total / JOINS)
    local joins, left = {}, total
    for k = 1, #points - 1 do
        local a, b = points[k], points[k + 1]
        for i = 0, math.floor(lengths[k] / every) do
            local t = lengths[k] > 0 and i * every / lengths[k] or 0
            joins[#joins + 1] = {
                a[1] + (b[1] - a[1]) * t,
                a[2] + (b[2] - a[2]) * t,
                left = left - lengths[k] * t,
                leg = k,
            }
        end
        left = left - lengths[k]
    end
    return joins
end

--- The way found (nil: none): it is the way shown from now on, the planned walk after its join.
local function Found(key, route, why, north, west)
    if live.key ~= key then return end
    live.job, live.time, live.at = nil, GetTime and GetTime() or 0, { north, west }
    if not route then
        live.state, live.why = "failed", why
        return
    end
    local points = route.points
    if route.join then
        for k = route.join.leg + 1, #planned.points do
            points[#points + 1] = planned.points[k]
        end
    end
    walk = { continent = planned.continent, points = points, live = true }
    reached = 1
    live.state, live.why, live.yards, live.explored = "found", nil, route.yards, route.explored
    if FG.PathLines then FG.PathLines:Refresh() end
end

--- Look for the way from (`north`, `west`) when it is time to: none yet for this place, the
--- character off the one found, or enough moved or waited since none was found.
function Pathing:Live(continent, north, west)
    if not planned or planned.continent ~= continent or not walkPlace then return end
    -- On a flight the ground under the character is not where it walks.
    if UnitOnTaxi and UnitOnTaxi("player") then return end
    local now = GetTime and GetTime() or 0
    if live.job or (live.checked and now - live.checked < LIVE_EVERY and now >= live.checked) then return end
    live.checked = now
    if not self:LiveWanted(continent) then
        -- Turned off: back to the guide's walk.
        if walk ~= planned then
            walk, reached = planned, 1
            ForgetLive()
        end
        return
    end
    local place = planned.points[#planned.points]
    local away = math.sqrt((place[1] - north) ^ 2 + (place[2] - west) ^ 2)
    local since = now - (live.time or 0)
    local need
    if live.state == nil then
        need = away > SHORT
    elseif live.state == "found" then
        -- Off the way found (from the leg reached on): looked for again from here.
        local _, off = Closest(north, west)
        need = off ~= nil and off > OFF and since > AGAIN and away > SHORT
    else
        -- None found: not looked for again at once (a search that finds none is the longest).
        local moved = live.at and math.sqrt((live.at[1] - north) ^ 2 + (live.at[2] - west) ^ 2) or math.huge
        need = away > SHORT and since > RETRY and (moved > MOVED or since > RETRY * 4)
    end
    if not need then return end
    local key = Key(walkPlace)
    live.key = key
    local indoors
    if IsIndoors then indoors = IsIndoors() and true or false end
    live.job = FG.Walker:Start({
        map = continent,
        north = north,
        west = west,
        indoors = indoors,
        target = { place[1], place[2] },
        joins = #planned.points > 1 and Joins() or nil,
    }, function(route, why) Found(key, route, why, north, west) end)
end

--- What the way from here is doing, for `/pw way`: its state and numbers.
function Pathing:LiveState()
    return {
        wanted = FG:Get("pathLive") == true,
        state = live.job and "searching" or live.state or "none",
        why = live.why,
        yards = live.yards,
        explored = live.explored,
        points = walk and walk.live and #walk.points or nil,
    }
end

--- `/pw way`: say in the chat what the way from here is doing.
function Pathing:Say()
    local s = self:LiveState()
    if not s.wanted then
        FG:Print(FG.T("way: found from where you stand is turned off (Options, Path)"))
    elseif s.state == "found" then
        FG:Print(
            FG.T("way: found, %d yards, %d turns (%d floors looked at)"),
            s.yards or 0,
            s.points or 0,
            s.explored or 0
        )
    elseif s.state == "searching" then
        FG:Print(FG.T("way: looking for the way..."))
    elseif s.state == "failed" then
        FG:Print(FG.T("way: none found (%s); the guide's own walk is shown"), tostring(s.why))
    else
        FG:Print(FG.T("way: nothing to look for here (no place, too close, or Shortest Path Forever guides)"))
    end
end

--- Where the compass shows the way for a character at (`north`, `west`) of `continent`: AHEAD
--- yards along the walk from its closest point; nil without a walk, off it, or on its last leg
--- (straight to the place). Second value: true when the character is beside the walk, going
--- back to it. While Shortest Path Forever guides: the next point of its way (see Pathing:Way).
function Pathing:Aim(continent, north, west)
    local way = self:Way()
    if way then
        if way.continent ~= continent then return nil end
        return way.north, way.west, false
    end
    if not walk or walk.continent ~= continent or not self:PathShown() then return nil end
    self:Live(continent, north, west)
    local points = walk.points
    local best, bestDistance, bestN, bestW = Closest(north, west)
    if not best or bestDistance > REJOIN then return nil end
    reached = best
    if best == #points - 1 then return nil end
    local n, w, left, k = bestN, bestW, AHEAD, best
    while left > 0 and k < #points do
        local to = points[k + 1]
        local leg = math.sqrt((to[1] - n) ^ 2 + (to[2] - w) ^ 2)
        if leg >= left then
            n, w, left = n + (to[1] - n) * left / leg, w + (to[2] - w) * left / leg, 0
        else
            n, w, left, k = to[1], to[2], left - leg, k + 1
        end
    end
    return n, w, bestDistance > CORRIDOR
end

--- The walk left to the place for a character at (`north`, `west`) of `continent`, to draw it:
--- { { north, west }, ... } from the character (or from the walk's closest point when on it) to
--- the place; the whole walk left when far from it; nil without a walk or with it not shown.
function Pathing:Remaining(continent, north, west)
    if not walk or walk.continent ~= continent or not self:PathShown() then return nil end
    self:Live(continent, north, west)
    local points = walk.points
    local out = {}
    local best, bestDistance, bestN, bestW = Closest(north, west)
    if not best then
        out[1] = { north, west }
    elseif bestDistance > REJOIN then
        for k = reached, #points - 1 do
            out[#out + 1] = points[k]
        end
    else
        if bestDistance > CORRIDOR then out[1] = { north, west } end
        out[#out + 1] = { bestN, bestW }
        for k = best + 1, #points - 1 do
            out[#out + 1] = points[k]
        end
    end
    out[#out + 1] = points[#points]
    return out
end

-- Shortest Path Forever -------------------------------------------------------------------

-- The place sent (its key), the one cleared or replaced by the player (not sent again until
-- the target changes), and the subscription to changes.
local sent, refused, subscribed
-- Its way, read at most every WAY_EVERY seconds and when it says it changed: { continent,
-- north, west, text }, false without one, nil to read again.
local way, wayRead
local WAY_EVERY = 0.5

--- The next point Shortest Path Forever leads to on the guide's journey, and its leg's words.
local function ReadWay(api)
    if type(api.Guidance) ~= "function" then return false end
    local guidance = api.Guidance()
    local point = type(guidance) == "table" and guidance.owner == OWNER and guidance.point
    if type(point) ~= "table" then return false end
    local continent, north, west = FG.Compass.World(point.map, point.x, point.y)
    if not continent then return false end
    local journey = type(api.Journey) == "function" and api.Journey()
    local leg = type(journey) == "table"
        and journey.owner == OWNER
        and type(journey.legs) == "table"
        and journey.legs[1]
    local text = type(leg) == "table" and type(leg.text) == "string" and leg.text ~= "" and leg.text or nil
    return { continent = continent, north = north, west = west, text = text }
end

local function Changed()
    way = nil
    local api = API()
    if not api or not sent or (api.CurrentStop and api.CurrentStop(OWNER)) then return end
    local why = api.Ended and api.Ended(OWNER)
    -- Arrived: not sent again either, while the place stays the same.
    if why == "replaced" or why == "cleared" then refused, sent = sent, nil end
end

local function Cancel(api)
    if sent and api and api.Cancel then api.Cancel(OWNER) end
    sent, way = nil, nil
end

-- The NPC standing at the place pointed at.
local targetNpc

--- The place the guide points at (nil: none), with what stands there: { title, kind (a step's
--- or a compass place's), q (its quest), npc (its NPC ID) }.
function Pathing:SetTarget(place, step, info)
    SetWalk(place, step)
    targetNpc = place and info and info.npc or nil
    if FG.NpcMark then FG.NpcMark:SetNpc(targetNpc) end
    local api = self:SpfLinked() and API()
    if not api then return end
    if not subscribed and api.Subscribe then
        subscribed = true
        api.Subscribe(Changed)
    end
    if not place or not place.m or not place.x then
        Cancel(api)
        refused = nil
        return
    end
    local key = Key(place)
    if key ~= refused then refused = nil end
    if key == sent or key == refused then return end
    info = info or {}
    local stop = { map = place.m, x = place.x / 100, y = place.y / 100, title = info.title, kind = KINDS[info.kind] }
    if info.kind == "objective" or info.kind == "grind" then
        stop.hold, stop.radius = true, AREA
        if info.q then stop.questID = info.q end
    end
    -- Refused in combat, without a position or with its journeys turned off: tried again at the
    -- next refresh.
    if api.NavigateRoute(OWNER, { stop }) then
        sent, refused, way = key, nil, nil
    end
end

--- The NPC standing at the place pointed at (nil: none, or not an NPC).
function Pathing:TargetNpc() return targetNpc end

--- Whether Shortest Path Forever guides to the guide's place now (the game's waypoint is its).
function Pathing:Guiding()
    local api = self:SpfLinked() and API()
    return api ~= nil and sent ~= nil and (not api.CurrentStop or api.CurrentStop(OWNER) ~= nil)
end

--- The way Shortest Path Forever leads the character on the guide's journey: { continent, north,
--- west (the next point to go to: a turn of the walk, a flight master, a dock), text (what its
--- leg says, in the game's language; nil without) }; nil when it does not guide there, has no
--- point to give (still planning, paused, inside an objective's area) or the compass shows the
--- guide's own walk or none (`pathMode`).
function Pathing:Way()
    if FG:Get("pathMode") ~= "auto" or not sent then return nil end
    local now = GetTime and GetTime() or 0
    if way == nil or now - (wayRead or 0) > WAY_EVERY or now < (wayRead or 0) then
        local api = self:SpfLinked() and API()
        way, wayRead = api and ReadWay(api) or false, now
    end
    return way or nil
end

--- The place is picked by hand (a click on the compass): sent again, even refused before.
function Pathing:Forget()
    sent, refused, way = nil, nil, nil
end

FG:OnSetting("spfLink", function(on)
    if not on then Cancel(API()) end
    refused = nil
    if FG.Guide then FG.Guide:Refresh() end
end)
FG:OnSetting("pathMode", function()
    if FG.Guide then FG.Guide:Refresh() end
end)
