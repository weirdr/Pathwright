-- The walkable ground of the game, as the app's pathfinder has it (crates/fg-route/src/terrain):
-- cells of 8.33 yards, up to 8 floors in each (the terrain's surface first, then caves, bridges,
-- the floors of buildings), and the steps between them. Terrain/Tiles*.lua hold it, a string a
-- tile of 64 x 64 cells, written by addon/tools/terrain_export.py (the format is told there);
-- a tile is read when a walk first needs it, and the least used are forgotten.
--
-- A floor is named by a number, its node: ((row * 4096) + column) * 8 + floor. Rows count
-- from the north, columns from the west, as the app's.

local FG = Pathwright

local Terrain = {}
FG.Terrain = Terrain

local TILE = 1600 / 3
local CELL = TILE / 64
local ORIGIN = 32 * TILE
Terrain.CELL = CELL
-- A floor's flags: stood on, swum, with a full record, in a cell of several floors; what the
-- floor is in the bits above (KIND_*).
local STAND, SWIM, FULL, MULTI = 1, 2, 4, 8
Terrain.STAND, Terrain.SWIM, Terrain.MULTI = STAND, SWIM, MULTI
Terrain.KIND_SURFACE, Terrain.KIND_UNDER, Terrain.KIND_ABOVE, Terrain.KIND_MODEL = 16, 32, 64, 128
-- The steps: north, south, west, east, north-west, north-east, south-west, south-east.
local DR = { -1, 1, 0, 0, -1, -1, 1, 1 }
local DC = { 0, 0, -1, 1, -1, 1, -1, 1 }
Terrain.DR, Terrain.DC = DR, DC
-- Tiles kept read at most.
local KEPT = 80

local byte, sub, floor = string.byte, string.sub, math.floor

--- The cell (row, column) of a world position (yards north, yards west).
function Terrain.Cell(north, west) return floor((ORIGIN - north) / CELL), floor((ORIGIN - west) / CELL) end

--- The world position of a cell's middle.
function Terrain.Middle(row, column) return ORIGIN - (row + 0.5) * CELL, ORIGIN - (column + 0.5) * CELL end

--- Whether the ground of `map` (a continent: 0, 1...) is known.
function Terrain.Has(map)
    local known = Terrain.maps
    if not known then
        known = {}
        for key in pairs(FG.TerrainData or {}) do
            known[tonumber(key:match("^(%d+):")) or -1] = true
        end
        Terrain.maps = known
    end
    return known[map] == true
end

-- Reading a tile ------------------------------------------------------------------------------

local B64 = {}
for i = 1, 64 do
    B64[("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"):byte(i)] = i - 1
end

--- Base 64 read without the game's help.
local function Decode64(text)
    local out, n, char = {}, 0, string.char
    for i = 1, #text, 4 do
        local a, b, c, d = byte(text, i, i + 3)
        local v = B64[a] * 262144 + B64[b] * 4096 + (B64[c] or 0) * 64 + (B64[d] or 0)
        n = n + 1
        if not B64[c] then
            out[n] = char(floor(v / 65536))
        elseif not B64[d] then
            out[n] = char(floor(v / 65536), floor(v / 256) % 256)
        else
            out[n] = char(floor(v / 65536), floor(v / 256) % 256, v % 256)
        end
    end
    return table.concat(out)
end

--- A tile's bytes from its text: the game's own inflate where it has one, else LibDeflate.
local function Inflate(text)
    local util = C_EncodingUtil
    local method = Enum and Enum.CompressionMethod and Enum.CompressionMethod.Zlib
    if util and util.DecodeBase64 and util.DecompressString and method then
        local ok, data = pcall(function() return util.DecompressString(util.DecodeBase64(text), method) end)
        if ok and type(data) == "string" and #data >= 8195 then return data end
    end
    local deflate = LibStub and LibStub("LibDeflate", true)
    if not deflate then return nil end
    local ok, data = pcall(function() return (deflate:DecompressZlib(Decode64(text))) end)
    return ok and type(data) == "string" and data or nil
end

--- A tile read from its bytes: its first floors' steps and flags (strings of 4096), and for the
--- cells of several floors where their other floors are.
local function Read(data)
    if byte(data, 1) ~= FG.TerrainFormat then return nil end
    local nFull = byte(data, 2) + byte(data, 3) * 256
    local tile = {
        data = data,
        masks = sub(data, 4, 4099),
        flags = sub(data, 4100, 8195),
        -- A cell's other floors: how many floors it has, and the number of its second among
        -- the tile's other floors (from 0).
        count = {},
        base = {},
        -- A first floor's full record: its number among them (from 0).
        full = {},
    }
    local flags, counts = tile.flags, 8195
    local multi, extras, fulls = 0, 0, 0
    for cell = 0, 4095 do
        local f = byte(flags, cell + 1) % 16
        if f >= MULTI then
            multi = multi + 1
            local count = byte(data, counts + multi)
            tile.count[cell], tile.base[cell] = count, extras
            extras = extras + count - 1
            f = f - MULTI
        end
        if f >= FULL then
            tile.full[cell] = fulls
            fulls = fulls + 1
        end
    end
    if fulls ~= nFull then return nil end
    -- The other floors' flags, then every full record (first floors, then the others): the
    -- byte before each.
    tile.extraFlags = counts + multi
    tile.records = tile.extraFlags + extras
    tile.extraRecords = tile.records + nFull * 9
    if #data ~= tile.extraRecords + extras * 9 then return nil end
    return tile
end

local tiles, kept, clock = {}, 0, 0

--- The tile at (tile row, tile column) of `map`; false when the ground there is not known.
function Terrain.Tile(map, tr, tc)
    local key = map * 4096 + tr * 64 + tc
    local tile = tiles[key]
    if tile == nil then
        local text = FG.TerrainData and FG.TerrainData[map .. ":" .. tr .. ":" .. tc]
        local data = text and Inflate(text)
        tile = data and Read(data) or false
        tiles[key] = tile
        if tile then
            kept = kept + 1
            if kept > KEPT then Terrain.Forget(KEPT * 3 / 4) end
        end
    end
    if tile then
        clock = clock + 1
        tile.used = clock
    end
    return tile
end

--- Keep only the `most` tiles used last (all forgotten when nil).
function Terrain.Forget(most)
    if not most then
        tiles, kept = {}, 0
        return
    end
    local order = {}
    for key, tile in pairs(tiles) do
        if tile then order[#order + 1] = { key, tile.used or 0 } end
    end
    table.sort(order, function(a, b) return a[2] > b[2] end)
    for i = floor(most) + 1, #order do
        tiles[order[i][1]] = nil
        kept = kept - 1
    end
end

--- How many tiles are read now.
function Terrain.Kept() return kept end

-- Floors ---------------------------------------------------------------------------------------

--- The flags of floor `f` of cell (row, column) of `map`: 0 when there is none.
function Terrain.Flags(map, row, column, f)
    if row < 0 or column < 0 then return 0 end
    local tile = Terrain.Tile(map, floor(row / 64), floor(column / 64))
    if not tile then return 0 end
    local cell = (row % 64) * 64 + column % 64
    if f == 0 then return byte(tile.flags, cell + 1) end
    local count = tile.count[cell]
    if not count or f >= count then return 0 end
    return byte(tile.data, tile.extraFlags + tile.base[cell] + f)
end

--- How many floors cell (row, column) of `map` has.
function Terrain.Floors(map, row, column)
    if row < 0 or column < 0 then return 0 end
    local tile = Terrain.Tile(map, floor(row / 64), floor(column / 64))
    if not tile then return 0 end
    local cell = (row % 64) * 64 + column % 64
    local count = tile.count[cell]
    if count then return count end
    return byte(tile.flags, cell + 1) > 0 and 1 or 0
end

--- The floors of the neighbour in direction `d` (1 to 8; 9: the same cell, dropped to) that
--- floor `f` of cell (row, column) steps to: bit j for its floor j. 0 without any.
function Terrain.Steps(map, row, column, f, d)
    local tile = Terrain.Tile(map, floor(row / 64), floor(column / 64))
    if not tile then return 0 end
    local cell = (row % 64) * 64 + column % 64
    local at
    if f == 0 then
        local full = tile.full[cell]
        if not full then
            if d == 9 then return 0 end
            return floor(byte(tile.masks, cell + 1) / 2 ^ (d - 1)) % 2
        end
        at = tile.records + full * 9
    else
        local count = tile.count[cell]
        if not count or f >= count then return 0 end
        at = tile.extraRecords + (tile.base[cell] + f - 1) * 9
    end
    return byte(tile.data, at + d)
end
