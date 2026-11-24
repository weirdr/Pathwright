-- guide_dump.lua <guide file>...: each guide as one line of JSON (for addon/tools/guide_validate.py).
-- Runs the guide files as the game would, with a Register that keeps what they hand over. Works
-- with luajit and with lua 5.1 to 5.4.
local out
Pathwright = { Builtin = { Register = function(guide) out = guide end } }
-- The RestedXP pack's files register through their addon table (Pathwright_RxPForever/Register.lua
-- drops the steps of the other game mode in game: here every step is kept, with its rxpMode).
local pack = { Register = function(guide) out = guide end }

local escapes = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function str(s)
    return '"' .. s:gsub('[%c"\\]', function(c) return escapes[c] or string.format("\\u%04x", c:byte()) end) .. '"'
end

local function json(v)
    local t = type(v)
    if t == "table" then
        local parts = {}
        if #v > 0 or next(v) == nil then
            for i = 1, #v do
                parts[i] = json(v[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do
            keys[#keys + 1] = tostring(k)
        end
        table.sort(keys)
        for i, k in ipairs(keys) do
            parts[i] = str(k) .. ":" .. json(v[k])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    elseif t == "string" then
        return str(v)
    elseif t == "number" then
        if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return string.format("%d", v) end
        return string.format("%.14g", v)
    elseif t == "boolean" then
        return v and "true" or "false"
    end
    return "null"
end

for i = 1, #arg do
    out = nil
    local chunk, err = loadfile(arg[i])
    if not chunk then
        io.stderr:write(err, "\n")
        os.exit(1)
    end
    chunk("guide_dump", pack)
    if out then
        out.file = arg[i]
        io.write(json(out), "\n")
    end
end
