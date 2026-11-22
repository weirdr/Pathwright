-- show.lua <guide file> [variant]: the steps (of one variant), one line each.
Pathwright = { Builtin = { Register = function(d) G = d end } }
dofile(arg[1])
local want = tonumber(arg[2])
local function has(t, v)
    for _, x in ipairs(t) do
        if x == v then return true end
    end
end
for i, s in ipairs(G.steps) do
    if not want or not s.only or has(s.only, want) then
        print(
            string.format(
                "%3d %-9s L%-2s %-62s %s %s%s%s%s",
                i,
                s.k,
                s.lvl or "?",
                (s.t or ""):sub(1, 62),
                s.m and string.format("%d %.1f,%.1f", s.m, s.x, s.y) or "NOPLACE",
                s.only and ("[" .. table.concat(s.only, ",") .. "] ") or "",
                s.bg and "bg " or "",
                s.mobs and ("mobs=" .. table.concat(s.mobs, "/") .. " ") or "",
                s.nt and "tip " or ""
            )
        )
    end
end
