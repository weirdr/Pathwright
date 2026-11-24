# Overwatch

## Task grouping
- One change per pull request: a fix or a feature with its tests, its changelog lines and any data
  or generated file it needs, together.
- Keep the repository's parts apart unless one change really spans them: the planner and its
  crates (`crates/`, `overrides/`, `notes/`, `data/`), the app's frontend (`app/`), the in-game
  addon (`addon/`), the updater (`crates/pathwright-updater/`) and the feedback relay (`relay/`).
  A change to the guide format that the app writes and the addon reads goes in one pull request
  with both sides.
- Data corrections (an `overrides/` entry, a quest note under `notes/`, a map marker) for the same
  zone or quest chain can share a pull request; unrelated zones get their own.
- Regenerating a generated file (built-in guides, `StatsData.lua`, `QuestItems.lua`,
  `TalentBuilds_*.lua`, `SettingsSchema.lua`, test fixture bases) goes with the change to its
  source that called for it, never mixed with unrelated hand edits.

## Conventions
- Commit messages and pull request titles are one plain sentence saying what changes for the
  player or the code, in the present tense ("Pass hearthstone steps when the hearthstone is on a
  long cooldown"); the body says why and how.
- Comments explain why, in full sentences; keep the existing comments' tone and keep them true
  when you change the code.
- Changelogs: every change a player can see gets one short line under `## Unreleased` in the root
  `CHANGELOG.md` (grouped under App, Guides, Addon and WoW data), saying what the player sees, not
  how it works. An addon change also goes, in the same words, under `## Unreleased` in
  `addon/<addon>/CHANGELOG.md`. Never add a version heading: `scripts/release.sh` dates them.
- Rust (edition 2024, toolchain pinned in `rust-toolchain.toml`): `cargo fmt` (`rustfmt.toml`),
  and clippy clean with `-D warnings` under the workspace lints of `Cargo.toml` (pedantic, no
  `unwrap()`, no `dbg!`, no `todo!`, `#[expect]` rather than `#[allow]`). `unsafe` is denied; the
  only exception is the browser allocator in `fg-web`. `fg-web` must not depend on `parking_lot`
  (its locks panic in the browser; `scripts/check.sh` checks it). Planner jobs fail with
  `job::JobError`, app commands with `CmdError`.
- Crate roles (ARCHITECTURE.md §5): `fg-route` plans, replays and writes guides; `fg-library`
  keeps a player's guides; `fg-app` is what the page calls, through a `Host`; `fg-web` (browser,
  WebAssembly) and `app/src-tauri` (desktop) are the two hosts. Put code in the crate whose job it
  is, and keep both hosts working.
- Planner tests never read the game databases: they declare the small world they need in
  `crates/fg-route/tests/fixtures/*.toml` and build it with `fg_route::fixture::Fixture`
  (ARCHITECTURE.md §6). A test of what the planner does with a quest declares that quest. Iterate
  with `cargo test --profile fast -p fg-route --test it <name>`; the planner tests are too slow in
  debug.
- Frontend (`app/`, React + TypeScript, Vite): `tsc` and `oxlint --deny-warnings` clean. Every
  text shown goes through `t("...")` with an English entry in `app/src/catalog.ts`
  (`npm run check:i18n`).
- Addon (`addon/`, Lua for the WoW client, LuaJIT in tests): format the Lua files you change with
  StyLua 2.5.2 (`stylua.toml`; `npx -y @johnnymorganz/stylua-bin@2.5.2 <files>`). Do not
  reformat files you do not otherwise touch. Each addon folder must keep working without the other
  (`Pathwright_Guide` and `Pathwright_Profile`). Guides written by older apps must stay readable:
  `addon/tests/guides` keeps one per release and the smoke tests replay them.
- Generated files say so in their first line; never edit them by hand. Change the source and run
  the generator: `addon/settings.json` then `luajit addon/tools/settings.lua` for
  `SettingsSchema.lua`; `addon/guides/*.guide` then `scripts/build-builtin-guides.sh` (or
  `addon/tools/guide_build.py`) for `addon/Pathwright_Guide/Builtin/`;
  `addon/tools/stats_data.py`, `addon/tools/quest_items.py` and `fg talents` for `StatsData.lua`,
  `QuestItems.lua` and `TalentBuilds_*.lua`; `scripts/test-base.sh` and `scripts/test-terrain.sh`
  for the fixture bases in `crates/fg-route/tests/fixtures/*.sqlite.zst`.
- Game data: correct the planner through `overrides/` (TOML, with a comment or `reason` saying why
  it is right), quest notes through `notes/*.toml` (format in `notes/README.md`, in your own
  words, 300 characters at most), never by editing `data/*.sqlite.zst` by hand.
- Shell scripts in `scripts/` are `#!/bin/sh` with `set -eu` (bash only where needed) and pass
  `shellcheck`.
- Workflows pin actions by commit SHA and pass `zizmor`.

## Review focus
- Planner correctness: a change to routing, XP, timing or prerequisites must not make guides
  impossible (a quest that cannot be taken, a broken chain) or silently slower; look for a fixture
  test that shows the new behaviour.
- Compatibility between the app and the addon: the guide format, saved variables and the
  `FGP1:` / `FGG1:` texts. Older guides (`addon/tests/guides`) and older saved data must still load.
- Addon runtime safety in the WoW client: nil checks on game API results, nothing protected done in
  combat, no errors on load when the other addon folder is missing, and the WoW Forever, Classic
  Era and TBC differences.
- Both hosts: a change in `fg-app` or `fg-route` must work in the desktop app and in the browser
  build (`fg-web`: files in memory, no `parking_lot` locks).
- Data sources and licences: quest notes and guides in our own words, nothing copied; new data
  sources listed in `NOTICE.md`.
- Untrusted input: the relay (`relay/worker.js`) and imported texts and `.fgguide` files come
  from strangers; mentions, markup and sizes must stay defused.
- Changelog lines present for player-visible changes, in the player's words.

## Protected paths
- .github/workflows/
- LICENSE
- data/LICENSE
- NOTICE.md
- addon/Pathwright_Guide/Libs/
- addon/Pathwright_Profile/Libs/
- relay/worker.js

## Test commands

### Rust
Paths: crates/**, app/src-tauri/**, overrides/**, notes/**, data/**, Cargo.toml, Cargo.lock, rust-toolchain.toml, rustfmt.toml, clippy.toml, deny.toml, .cargo/**
Build: cargo fmt --all --check
Build: cargo clippy --workspace --exclude factoruide-app --exclude pathwright-updater --all-targets --locked -- -D warnings
- cargo fmt --all --check
- cargo clippy --workspace --exclude factoruide-app --exclude pathwright-updater --all-targets --locked -- -D warnings
- cargo test --workspace --exclude factoruide-app --exclude pathwright-updater --locked --release

### Frontend
Paths: app/**, !app/src-tauri/**
Build: cd app && npm ci && npm run build
Build: cd app && npm ci && npx oxlint --deny-warnings
Build: cd app && npm ci && npm run check:i18n
Unit: cd app && npm test
- cd app && npm ci
- cd app && npm run build
- cd app && npm test
- cd app && npx oxlint --deny-warnings
- cd app && npm run check:i18n

### Relay
Paths: relay/**
Build: node --check relay/worker.js
- node relay/test.mjs

### Addon
Paths: addon/**, scripts/addon-test.sh, scripts/install-addon.sh, scripts/addon-zip.sh
- luajit addon/tests/smoke.lua
- luajit addon/tests/smoke.lua profile
