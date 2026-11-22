-- The guides built into the addon (Builtin\*.lua, listed in Builtin\Builtin.xml), beside those the
-- app computes and those imported. Each file calls `Pathwright.Builtin.Register(def)`:
--
--   def = { name, origin, fromLevel, toLevel, locale, version, format, created, next (the guide
--           that follows: opened when this one ends),
--           variants = { { race, class, faction }, ... },
--           steps = { step, ... } }   -- a step with `only = { variant index, ... }` is for those only
--
-- One guide is offered per def, as a route like the app's (its steps those of the variant): the
-- variant made for the character (its race, class and faction), else the closest one (its class,
-- else its faction), so that any character can open it in a tab.

local FG = Pathwright

local Builtin = { defs = {} }
FG.Builtin = Builtin

--- Keep a guide def (called by the Builtin\*.lua files as they load).
function Builtin.Register(def)
    if type(def) ~= "table" or type(def.name) ~= "string" or type(def.steps) ~= "table" then return end
    if type(def.variants) ~= "table" then return end
    table.insert(Builtin.defs, def)
end

local function Has(list, v)
    for _, x in ipairs(list) do
        if x == v then return true end
    end
    return false
end

--- The route of variant `index` of `def`: its steps (without `only`), the variant's race, class
--- and faction.
function Builtin.Expand(def, index)
    local v = def.variants[index]
    if not v then return nil end
    local steps = {}
    for _, s in ipairs(def.steps) do
        if not s.only or Has(s.only, index) then
            local copy = {}
            for k, x in pairs(s) do
                if k ~= "only" then copy[k] = x end
            end
            steps[#steps + 1] = copy
        end
    end
    return {
        race = v.race,
        class = v.class,
        faction = v.faction,
        locale = def.locale,
        fromLevel = def.fromLevel,
        toLevel = def.toLevel,
        time = 0,
        levels = {},
        steps = steps,
        created = def.created,
        version = def.version,
        format = def.format,
        origin = def.origin,
        next = def.next,
        builtin = true,
    }
end

--- The index of the variant of `def` for this character: the one made for it, else the first of
--- its class (in its faction first), else the first of its faction, else the first. Nil while the
--- character is not known yet.
function Builtin.VariantFor(def)
    local _, _, race = UnitRace("player")
    local _, _, class = UnitClass("player")
    race, class = FG.Readable(race), FG.Readable(class)
    if not race or not class then return nil end
    local faction = FG.Readable(UnitFactionGroup("player"))
    local best, bestScore = nil, -1
    for i, v in ipairs(def.variants) do
        local sameFaction = not (v.faction and faction and v.faction ~= faction)
        local score = (v.race == race and v.class == class and sameFaction) and 8
            or (v.class == class and 4 or 0) + (sameFaction and 2 or 0)
        if score > bestScore then
            best, bestScore = i, score
        end
    end
    return best
end

local expanded = {} -- def -> { index, route }: expanded once per variant

--- The built-in guides for this character: { name -> route }.
function Builtin.Routes()
    local out = {}
    for _, def in ipairs(Builtin.defs) do
        local index = Builtin.VariantFor(def)
        if index then
            local cached = expanded[def]
            if not cached or cached.index ~= index then
                cached = { index = index, route = Builtin.Expand(def, index) }
                expanded[def] = cached
            end
            out[def.name] = cached.route
        end
    end
    return out
end
