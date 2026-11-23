local _, pack = ...
local hardcore = C_GameRules and C_GameRules.IsHardcoreActive and C_GameRules.IsHardcoreActive()
local mode = hardcore and "hardcore" or "softcore"
function pack.Register(guide)
    local steps = {}
    for _, step in ipairs(guide.steps) do
        if not step.rxpMode or step.rxpMode == mode then
            step.rxpMode = nil
            steps[#steps+1] = step
        end
    end
    guide.steps = steps
    Pathwright.Builtin.Register(guide)
end
