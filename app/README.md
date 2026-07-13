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

Build the Rust CLI first, then launch the menu bar app:

```sh
cd ..
cargo build --release
cd app
BRRRN_BIN=../target/release/brrrn swift run BrrrnBar
```

The app runs as an accessory with no Dock icon. Quit from the power button in
the menu footer.

## Binary lookup

The app checks, in order:

1. `BRRRN_BIN`
2. `/opt/homebrew/bin/brrrn`
3. `/usr/local/bin/brrrn`
4. `~/repos/kevin-dev/brrrn/target/release/brrrn`

## Friends

The app reads `~/.config/brrrn/config.json`, written by the CLI:

```sh
brrrn config set-hub https://your-worker.workers.dev
brrrn pit join <code> --as <handle>
brrrn submit
```

Pit boards refresh every five minutes. Local Claude Code and Codex numbers
refresh every minute and after filesystem changes (debounced by five seconds).
