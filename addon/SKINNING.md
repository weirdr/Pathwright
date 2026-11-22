# Skinning the Pathwright addon

The addon draws its frames in one place, `Pathwright_Guide/Skin.lua`: dark blue cards in the
Pathwright app's colors. With the `suiteSkin` setting on ("UI suite style" in `/pw`, the addon's page of the game's
options),
a loaded UI suite styles them instead.

## UI suites supported out of the box

| Suite | How |
|---|---|
| ElvUI | `Skins:AddCallbackForAddon("Pathwright_Guide", ...)`, then `SetTemplate("Transparent")`, `HandleButton`, `HandleItemButton`, `FontTemplate` |
| EllesmereUI | `EllesmereUI.RegisterSkin("Pathwright", ...)`: `Shell`, `Panel`, `Button`, `SquareIcon`, `Font` |
| SpartanUI | `SUI.Skins:Register("Pathwright", ...)`: `SetTemplate`, `SkinObj("Button", ...)` |

## Your own skin

```lua
if PathwrightAPI then
    PathwrightAPI.RegisterSkin("MySkin", function(frame, kind)
        -- kind: "window", "panel", "button" or "icon"
    end)
end
```

The function runs on every frame already made and on every frame made later. Frames:

| Frame | Kind | Fields |
|---|---|---|
| `PathwrightTodo` (full guide) | window | `accent` (top line), `zone`, `level`, `rows`, `nextRows` |
| `PathwrightMini` (minimal guide) | window | `accent`, `name`, `sub`, `dist` |
| `PathwrightMiniNext` (minimal guide's next steps) | panel | `title`, `rows` |
| the minimal guide's labels, the item and talent names near the action bars | panel | `text` or `name` |
| `PathwrightTracker` (quest panel) | panel | `line` (under the tabs) |
| `PWItemButton`, `PathwrightItemButton<n>` | icon | `icon`, `cooldown` |

The compass bar (`PathwrightCompass`), the arrow (`PathwrightArrow`), the mark above an NPC's
head (`PathwrightNpcMark`) are not boxes and are not skinned. The addon's settings are in the game's
own options (AddOns, Pathwright): the game draws them.

`PathwrightAPI.GetFrames()` returns `{ { frame = ..., kind = ... }, ... }` for the frames made so
far. `PathwrightAPI.version` is 2 since the frames above (1: `PathwrightNext`, `PathwrightTalents`).
