#!/bin/sh
# Copy the addon (Pathwright_Profile and Pathwright_Guide) into the WoW client. After a change:
# /reload in game (a full client restart is needed when files are added or a .toc changes).
# (As an addon site would; the guides of `fg route`, addon/Pathwright_Data, with FG_INSTALL_DATA=1
# only. Existing Config.lua, Routes.lua, Services.lua and Sent.lua written by older apps are kept.)
set -eu
wow_dir=${FG_WOW_DIR:-"/mnt/g/Jeux/World of Warcraft"}
client=${FG_CLIENT:-$([ -d "$wow_dir/_forever_" ] && echo _forever_ || echo _classic_beta_)}
addons="$wow_dir/$client/Interface/AddOns"
repo="$(dirname "$0")/../addon"
# No migration of the upstream Factoruide addons: this fork's addons sit beside them, untouched.
for addon in Pathwright_Profile Pathwright_Guide; do
    dest="$addons/$addon"
    src="$repo/$addon"
    mkdir -p "$dest"
    for f in "$dest"/*.lua "$dest"/*.toc "$dest"/*.xml; do
        [ -e "$f" ] || continue
        case "$(basename "$f")" in Config.lua | Routes.lua | Services.lua | Sent.lua) continue ;; esac
        rm -f "$f"
    done
    for f in "$src"/*.lua "$src"/*.toc "$src"/*.xml; do
        [ -e "$f" ] || continue
        name=$(basename "$f")
        case "$name" in Sent.lua) continue ;; esac
        if { [ "$name" = "Config.lua" ] || [ "$name" = "Routes.lua" ] || [ "$name" = "Services.lua" ]; } \
            && [ -e "$dest/$name" ]; then
            continue
        fi
        cp "$f" "$dest/"
    done
    # Libraries.
    if [ -d "$src/Libs" ]; then
        rm -rf "$dest/Libs"
        cp -r "$src/Libs" "$dest/Libs"
    fi
    # Translations.
    if [ -d "$src/Locales" ]; then
        rm -rf "$dest/Locales"
        mkdir -p "$dest/Locales"
        cp "$src"/Locales/*.lua "$dest/Locales/"
    fi
    # Textures.
    if [ -d "$src/Media" ]; then
        mkdir -p "$dest/Media"
        cp "$src"/Media/*.tga "$dest/Media/"
    fi
    echo "installed into $dest"
done
# The guides planned with `fg route` (the data addon it writes), only when asked
# (FG_INSTALL_DATA=1): the game's Pathwright_Data holds the guides the app wrote, never replaced.
if [ "${FG_INSTALL_DATA:-}" = 1 ] && [ -f "$repo/Pathwright_Data/Data.lua" ]; then
    rm -rf "$addons/Pathwright_Data"
    cp -r "$repo/Pathwright_Data" "$addons/Pathwright_Data"
    echo "installed into $addons/Pathwright_Data"
fi
