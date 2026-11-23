# Pathwright Updater

A small system tray app (macOS and Windows) that keeps the Pathwright addon up to date.

- Every 15 minutes, and on **Check for updates now**, it looks at this repository's addon
  releases (tags `addon-…`, published by `.github/workflows/addon-release.yml`).
- When one is newer than the one it installed, it downloads its `Pathwright-addon.zip` and
  installs it into WoW Forever's `Interface/AddOns` folder, quietly. The game uses it at the next
  `/reload` or login (a full restart when an update adds files).
- Each addon folder of the zip replaces the installed one as a whole, keeping the files the
  Pathwright desktop app writes there (`Config.lua`, `Routes.lua`, `Services.lua`, `Sent.lua`).
  The new folders are unpacked next to AddOns first and then swapped in, so a failed update
  leaves the installed addon as it was. Other addons are never touched.
- It finds World of Warcraft by itself (Battle.net's list of installed games, then the usual
  folders). **Choose WoW folder…** takes the game's folder, its `_forever_` folder or AddOns.
- It starts at login from its first run; **Start at login** in its menu turns that off.

Its settings are in `settings.json` under the system's config folder, `Pathwright Updater`
(`~/Library/Application Support` on macOS, `%APPDATA%` on Windows).

## Building

    cargo build --release -p pathwright-updater
    cargo test -p pathwright-updater -- --include-ignored   # the last test downloads the latest release

Releases are built by `.github/workflows/updater-release.yml` when the version in `Cargo.toml`
changes on main: a universal macOS app (zipped) and a Windows exe, under the tag
`updater-vX.Y.Z`. Neither is signed by a developer account: Windows SmartScreen and macOS
Gatekeeper warn the first time (Windows: More info, Run anyway; macOS: right-click, Open).
