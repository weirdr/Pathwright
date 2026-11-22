-- Check a built-in guide against another one (a Zygor guide converted by zygor_convert.lua):
-- the quests one has and not the other, and the steps whose place or NPC differ.
--
--   luajit addon/tools/guide_compare.lua addon/Pathwright_Guide/Builtin/SkyborneStarter.lua \
--       debug/zygor/SkyborneStarter.lua [uiMap of the other's steps to compare, default 2521]
local function load(path)
    local G
    Pathwright = { Builtin = { Register = function(d) G = d end } }
    dofile(path)
    return G
end
local ours, zyg = load(arg[1]), load(arg[2])
local function index(G, map)
    local q, by = {}, {}
    for i, s in ipairs(G.steps) do
        if s.q and (not map or s.m == map) then
            q[s.q] = q[s.q] or { name = s.t, first = i }
            by[s.k .. s.q] = by[s.k .. s.q] or s
        end
    end
    return q, by
end
local oq, ob = index(ours)
local zq, zb = index(zyg, tonumber(arg[3]) or 2521)
print("== Zygor has, we do not:")
for id, v in pairs(zq) do
    if not oq[id] then print(id, v.name) end
end
print("== We have, Zygor does not:")
local list = {}
for id, v in pairs(oq) do
    if not zq[id] then list[#list + 1] = { id, v } end
end
table.sort(list, function(a, b) return a[2].first < b[2].first end)
for _, e in ipairs(list) do
    print(e[1], e[2].name)
end
print("== Place or NPC differs (> 1.5 map units):")
for key, s in pairs(ob) do
    local z = zb[key]
    if z and s.m and z.m and s.m == z.m then
        local d = math.sqrt((s.x - z.x) ^ 2 + (s.y - z.y) ^ 2)
        if d > 1.5 or (s.id and z.id and s.id ~= z.id and s.k ~= "objective") then
            print(
                string.format(
                    "%-10s %6d  ours %.1f,%.1f %s | zygor %.1f,%.1f %s",
                    s.k,
                    s.q,
                    s.x,
                    s.y,
                    s.n or "",
                    z.x,
                    z.y,
                    z.t or ""
                )
            )
        end
    end
end
