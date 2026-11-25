-- The flight map: when the guide's step says to fly somewhere, a green arrow bobs over that
-- destination on the flight master's map, so it is found at a glance among the others. So does
-- the flight of the journey to the step (Journey.lua: "Fly to ..."), when the guide's steps
-- ask for none themselves.
--
-- With "Take the step's flight automatically" on, the flight is taken as the map opens
-- (Automation.lua) and the arrow is hardly seen; it shows when that setting is off, when Shift
-- is held to choose by hand, or when the fly step is shown but is not the current one.
--
-- The destination is the step's flight point (its TaxiNodes ID): the map's nodes are asked for
-- theirs (C_TaxiMap), which holds in every language; where the client has no such list, the
-- node is found by its name (the step's is English). The arrow sits on the map's own button of
-- that node: TaxiButton<slot> on the flight map of Classic, the node's pin on the newer one.
-- A destination that cannot be flown to from here (not learned yet, another continent) gets no
-- arrow, and a line in the chat says so.

local FG = Pathwright
local T = FG.T
local Readable = FG.Readable
local Taxi = {}
FG.Taxi = Taxi

local TEXTURE = "Interface\\AddOns\\Pathwright_Guide\\Media\\TaxiArrow"
local SIZE = 30
--- The arrow bobs: how far up it goes (pixels), and how long one bob up and back takes (seconds).
local BOB, PERIOD = 8, 0.9
--- C_TaxiMap node states: where the character stands, where it can fly, where it cannot.
local UNREACHABLE = 2

local L = {
    none = T("%s is not a flight you can take from here."),
}

--- The flight the guide asks for now: the first "fly" step not taken among the steps shown,
--- else the current step when it is one, else the flight the journey to the step takes next
--- (as a step: { k = "fly", id, n }). Nil when no flight is asked.
function Taxi.Wanted()
    local Guide = FG.Guide
    local route, state = Guide and Guide:Route(), Guide and Guide:State()
    if not route or not state then return nil end
    for _, index in ipairs(Guide:CurrentSteps() or {}) do
        local step = route.steps[index]
        if step and step.k == "fly" and not (state.marks and state.marks[index]) then return step end
    end
    local step = route.steps[Guide:CurrentStep()]
    if step and step.k == "fly" then return step end
    local stop = FG.Pathing and FG.Pathing.Stop and FG.Pathing:Stop()
    local to = stop and stop.kind == "fly" and stop.to
    if not to or not to.id then return nil end
    -- The same table while the flight is the same (what was said of it is not said again).
    local flight = Taxi.journey
    if not flight or flight.id ~= to.id then
        flight = { k = "fly", id = to.id, n = to.name }
        Taxi.journey = flight
    end
    return flight
end

--- The map the flight map shows: the game says it, else the continent the character is on
--- (Classic Era and TBC have no GetTaxiMapID: the continent's map holds all its nodes).
local function MapID()
    local id = GetTaxiMapID and Readable(GetTaxiMapID())
    if id then return id end
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetMapInfo) then return nil end
    local here = Readable(C_Map.GetBestMapForUnit("player"))
    local map = here
    for _ = 1, 6 do
        local info = map and C_Map.GetMapInfo(map)
        if not info then break end
        if info.mapType == 2 then return map end
        map = info.parentMapID
    end
    return here
end

--- A flight point's name without its zone ("Undercity, Tirisfal Glades" -> "undercity").
local function Plain(name)
    if type(name) ~= "string" then return nil end
    return (name:match("^[^,]+") or name):lower():gsub("^%s+", ""):gsub("%s+$", "")
end

--- Where a fly step's destination is on the open flight map: its slot (the number of its
--- button, what TakeTaxiNode takes) and whether it can be flown to. Nil when it is not there.
function Taxi.Slot(step)
    if not step then return nil end
    local map = MapID()
    if step.id and map and C_TaxiMap and C_TaxiMap.GetAllTaxiNodes then
        local ok, nodes = pcall(C_TaxiMap.GetAllTaxiNodes, map)
        for _, node in ipairs(ok and type(nodes) == "table" and nodes or {}) do
            if node.nodeID == step.id then return node.slotIndex, node.state ~= UNREACHABLE end
        end
    end
    local wanted = Plain(step.n)
    if wanted and NumTaxiNodes and TaxiNodeName then
        for slot = 1, tonumber(Readable(NumTaxiNodes())) or 0 do
            if Plain(Readable(TaxiNodeName(slot))) == wanted then
                local kind = TaxiNodeGetType and Readable(TaxiNodeGetType(slot))
                return slot, kind == nil or kind == "REACHABLE" or kind == "CURRENT"
            end
        end
    end
    return nil
end

--- The map's own button of a node: Classic's TaxiButton<slot>, or the node's pin on the newer
--- flight map.
local function Pin(slot, id)
    local button = _G["TaxiButton" .. slot]
    if button and (not button.IsShown or button:IsShown()) then return button end
    local map = FlightMapFrame
    if map and map.EnumeratePinsByTemplate and (not map.IsShown or map:IsShown()) then
        for pin in map:EnumeratePinsByTemplate("FlightMap_FlightPointPinTemplate") do
            local data = pin.taxiNodeData
            if type(data) == "table" and (data.slotIndex == slot or (id and data.nodeID == id)) then return pin end
        end
    end
    return button
end

local function Arrow()
    if Taxi.arrow then return Taxi.arrow end
    local arrow = CreateFrame("Frame", "PathwrightTaxiArrow", UIParent)
    arrow:SetSize(SIZE, SIZE)
    arrow:SetFrameStrata("TOOLTIP")
    arrow.texture = arrow:CreateTexture(nil, "OVERLAY")
    arrow.texture:SetAllPoints()
    arrow.texture:SetTexture(TEXTURE)
    -- It bobs, up a little and back, for as long as it shows: placed anew each frame along a
    -- sine, which has no end to jump back from (a looping animation of the game snapped back
    -- to its start on this client).
    arrow.clock = 0
    arrow:SetScript("OnUpdate", function(self, elapsed)
        local pin = Taxi.pin
        if not pin then return end
        self.clock = (self.clock + (tonumber(elapsed) or 0)) % PERIOD
        local lift = BOB * (1 - math.cos(2 * math.pi * self.clock / PERIOD)) / 2
        self:SetPoint("BOTTOM", pin, "TOP", 0, 1 + lift)
    end)
    arrow:Hide()
    Taxi.arrow = arrow
    return arrow
end

function Taxi:Hide()
    self.pin = nil
    if self.arrow then self.arrow:Hide() end
end

--- Put the arrow over the destination of the flight the guide asks for, on the flight map open
--- now. `quiet`: say nothing when the destination cannot be flown to. Returns the button it
--- points at.
function Taxi:Show(quiet)
    self:Hide()
    if not self.open or not FG:Get("taxiArrow") then return nil end
    local step = Taxi.Wanted()
    if not step then return nil end
    local slot, reachable = Taxi.Slot(step)
    local pin = slot and reachable and Pin(slot, step.id)
    if not pin then
        if not quiet and step.n and self.told ~= step then
            self.told = step
            FG:Print(L.none, step.n)
        end
        return nil
    end
    local arrow = Arrow()
    arrow:SetParent(pin)
    arrow:SetFrameStrata("TOOLTIP")
    arrow:ClearAllPoints()
    arrow:SetPoint("BOTTOM", pin, "TOP", 0, 1)
    arrow.clock = 0
    self.pin = pin
    arrow:Show()
    return pin
end

FG:On("TAXIMAP_OPENED", function()
    Taxi.open, Taxi.told = true, nil
    -- The map lays its buttons out as it opens: once it has, and once more for a slow one.
    if C_Timer and C_Timer.After then
        C_Timer.After(0.1, function() FG:Try("taxi arrow", Taxi.Show, Taxi, true) end)
        C_Timer.After(0.6, function() FG:Try("taxi arrow", Taxi.Show, Taxi) end)
    else
        FG:Try("taxi arrow", Taxi.Show, Taxi)
    end
end)
FG:On("TAXIMAP_CLOSED", function()
    Taxi.open = false
    Taxi:Hide()
end)
