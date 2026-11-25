#!/bin/sh
# Copy Pathwright's addons into the WoW client, including its guide pack for Forever. After a change:
# /reload in game (a full client restart is needed when files are added or a .toc changes).
# (As an addon site would; the guides of `fg route`, addon/Pathwright_Data, with FG_INSTALL_DATA=1
# only. Existing Config.lua, Routes.lua, Services.lua and Sent.lua written by older apps are kept.)
set -eu
wow_dir=${FG_WOW_DIR:-"/mnt/g/Jeux/World of Warcraft"}
client=${FG_CLIENT:-$([ -d "$wow_dir/_forever_" ] && echo _forever_ || echo _classic_beta_)}
addons="$wow_dir/$client/Interface/AddOns"
repo="$(dirname "$0")/../addon"
# No migration of the upstream Factoruide addons: this fork's addons sit beside them, untouched.
set -- Pathwright_Profile Pathwright_Guide
if [ "$client" = "_forever_" ]; then
    set -- "$@" Pathwright_RxPForever
fi
for addon in "$@"; do
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
    # The built-in guides (Builtin/*.lua) and their index, Builtin.xml, which the TOC loads.
    if [ "$addon" = Pathwright_Guide ]; then
        rm -rf "$dest/Builtin"
        mkdir -p "$dest/Builtin"
        {
            echo '<Ui xmlns="http://www.blizzard.com/wow/ui/">'
            for f in "$src"/Builtin/*.lua; do
                [ -e "$f" ] || continue
                cp "$f" "$dest/Builtin/"
                echo "    <Script file=\"$(basename "$f")\"/>"
            done
            echo '</Ui>'
        } >"$dest/Builtin/Builtin.xml"
    fi
    # The walkable ground (Terrain/Tiles*.lua, then the passages) and its index, Terrain.xml,
    # which the TOC loads.
    if [ "$addon" = Pathwright_Guide ] && [ -d "$src/Terrain" ]; then
        rm -rf "$dest/Terrain"
        mkdir -p "$dest/Terrain"
        {
            echo '<Ui xmlns="http://www.blizzard.com/wow/ui/">'
            for f in "$src/Terrain/Tiles0.lua" "$src"/Terrain/Tiles*.lua "$src/Terrain/Passages.lua"; do
                [ -e "$f" ] || continue
                # Tiles0.lua first (it makes the table the others fill), once.
                if [ "$f" != "$src/Terrain/Tiles0.lua" ] || [ ! -e "$dest/Terrain/Tiles0.lua" ]; then
                    cp "$f" "$dest/Terrain/"
                    echo "    <Script file=\"$(basename "$f")\"/>"
                fi
            done
            echo '</Ui>'
        } >"$dest/Terrain/Terrain.xml"
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
