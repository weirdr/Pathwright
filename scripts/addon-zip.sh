#!/bin/sh
# Zip the addon to share it or publish it: every addon folder a fresh install makes
# (scripts/install-addon.sh: Pathwright_Profile, Pathwright_Guide with the built-in guides' index,
# and on WoW Forever its guide pack Pathwright_RxPForever), nothing of a player's own (the
# Config.lua, Routes.lua and Services.lua the repository ships empty).
#
#   scripts/addon-zip.sh                 # debug/Pathwright-addon.zip
#   scripts/addon-zip.sh dist/out.zip
#
# Unzipped into World of Warcraft/_forever_/Interface/AddOns, the folders sit there directly.
set -eu
cd "$(dirname "$0")/.."
out=${1:-debug/Pathwright-addon.zip}
case $out in /*) ;; *) out="$PWD/$out" ;; esac
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/_forever_/Interface/AddOns"
FG_WOW_DIR="$stage" FG_CLIENT=_forever_ scripts/install-addon.sh >/dev/null
# The installer never copies Sent.lua (it keeps the one an older app wrote); the TOC loads it:
# the repository's, empty.
cp addon/Pathwright_Profile/Sent.lua "$stage/_forever_/Interface/AddOns/Pathwright_Profile/Sent.lua"
mkdir -p "$(dirname "$out")"
rm -f "$out"
(
    cd "$stage/_forever_/Interface/AddOns"
    find . -name ".DS_Store" -delete
    # Whatever the installer put there, so an addon it gains is never left out.
    zip -qr -X "$out" -- *
)
echo "$out"
