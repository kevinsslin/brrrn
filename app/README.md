# BrrrnBar

Native macOS 14+ menu bar app for brrrn. The menu bar shows today's API-value
burn. The dropdown shows calendar week/month totals, source split, per-model
costs with hover token detail, private pit rankings, and clickable 14-day member
history.

## Build and test

```sh
swift build
swift test
```

## Build an app bundle

```sh
./scripts/build-app.sh
open dist/BrrrnBar.app
```

The bundle declares `LSUIElement`, so it has no Dock icon. Signing,
notarization, DMG packaging, and Sparkle updates are release automation work.

## Run during development

Run directly from SwiftPM during development:

```sh
cd app
BRRRN_BIN=../target/release/brrrn swift run BrrrnBar
```

`build-app.sh` builds and embeds the Rust CLI automatically, so the packaged
app does not depend on Homebrew or a source checkout.

The app runs as an accessory with no Dock icon. Quit from the power button in
the menu footer.

## Binary lookup

The app checks, in order:

1. `BRRRN_BIN`
2. `brrrn` bundled beside `BrrrnBar`
3. `/opt/homebrew/bin/brrrn`
4. `/usr/local/bin/brrrn`
5. `~/repos/kevin-dev/brrrn/target/release/brrrn`

`BRRRN_CONFIG` can override the normal `~/.config/brrrn/config.json` path
for development and end-to-end testing.

## Friends

The app reads `~/.config/brrrn/config.json`, written by the CLI:

```sh
brrrn config set-hub https://your-worker.workers.dev
brrrn pit join <code> --as <handle>
brrrn submit
```

Pit boards refresh every five minutes. Local Claude Code and Codex numbers
refresh every minute and after filesystem changes (debounced by five seconds).
