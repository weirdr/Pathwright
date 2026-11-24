# Pathwright Updater

A small system tray app (macOS and Windows) that keeps the Pathwright addon up to date.

- Every 15 minutes, and on **Check for updates now**, it looks at this repository's addon
  releases (tags `Pathwright-vX.Y.Z`, published by `.github/workflows/addon-release.yml`).
- When one is newer than the one it installed, it downloads its `Pathwright-addon.zip` and
  installs it into WoW Forever's `Interface/AddOns` folder, quietly. The game uses it at the next
  `/reload` or login (a full restart when an update adds files).
- Each addon folder of the zip replaces the installed one as a whole, keeping the files the
  Pathwright desktop app writes there (`Config.lua`, `Routes.lua`, `Services.lua`, `Sent.lua`).
  The new folders are unpacked next to AddOns first and then swapped in, so a failed update
  leaves the installed addon as it was. Other addons are never touched.
- It finds World of Warcraft by itself (Battle.net's list of installed games, then the usual
  folders). **Choose WoW folder…** takes the game's folder, its `_forever_` folder or AddOns.
- On its first run it asks whether to start at login; **Start at login** in its menu changes that.
- It sends the feedback reports made in the addon's "What went wrong?" window (the speech bubble
  under the guide): after the game reloads, it reads the report from the addon's saved data
  (`WTF/Account/<account>/SavedVariables/Pathwright_Profile.lua`, only the report's own lines),
  posts it to the project's relay (`relay/`), which opens a GitHub issue, and tells the addon the
  issue's address through `Pathwright_Guide/Updater.lua`. Nothing is sent without OK in that
  window, and nothing at all while `RELAY_URL` in `src/feedback.rs` is empty.

Its settings are in `settings.json` under the system's config folder, `Pathwright Updater`
(`~/Library/Application Support` on macOS, `%APPDATA%` on Windows).

## Building

    cargo build --release -p pathwright-updater
    cargo test -p pathwright-updater -- --include-ignored   # the last test downloads the latest release

`.github/workflows/updater-release.yml` builds it after each push to main that changes it and
publishes the builds to one release that always holds the newest (tag `updater`):
`PathwrightUpdater-Windows.msi` (the installer, built by `scripts/updater-msi.sh` from
`wix/main.wxs`; `PathwrightUpdater-Windows.exe` is the program alone),
`PathwrightUpdater-macOS-AppleSilicon.zip` and `PathwrightUpdater-macOS-Intel.zip`.
`.github/workflows/updater-ci.yml` builds the Windows ones for each pull request that changes
the updater. The repository's README links to them. Neither is signed by
a developer account: Windows SmartScreen and macOS Gatekeeper warn the first time (Windows: More
info, Run anyway; macOS: right-click, Open).
