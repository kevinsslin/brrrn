# Contributing to brrrn

Thanks for helping people burn tokens together. This page covers setup,
testing, and the conventions the codebase already follows.

## Setup

You need a Rust toolchain (stable), Swift 6 / Xcode command line tools on
macOS 14+, and Node 20+ for the hub.

```sh
git clone https://github.com/kevinsslin/brrrn
cd brrrn
cargo test
cd hub && npm test && cd ..
cd app && swift test && cd ..
```

Run the app against your working-tree engine:

```sh
cargo build --release
cd app
BRRRN_BIN=../target/release/brrrn swift run BrrrnBar
```

## Before you open a PR

```sh
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
cd hub && npm test
cd app && swift test
cd app && ./scripts/build-app.sh && ./scripts/measure-size.sh
```

CI runs exactly this, plus the 2 MB compressed-download budget. A PR that
grows the app past the budget needs a very good story.

If you touched any UI, regenerate the README screenshots so they keep
matching the build:

```sh
cd app && swift build && .build/debug/BrrrnBar --screenshots ../docs/screenshots
```

## Conventions

- **Conventional commits**: `feat(app): ...`, `fix(core): ...`,
  `feat(hub): ...`. Scopes are `core` (Rust), `app` (Swift), `hub`
  (Worker), `config`, `docs`.
- **Test-first for behavior**: parsing, dedupe, pricing, calendar windows,
  streaks, timezone re-bucketing, cache invalidation, Worker routes, and
  frozen JSON schemas all have tests; keep it that way. View *logic* lives
  in `BrrrnCore` so it is testable without rendering.
- **Frozen JSON schema**: the `--json` output is decoded by the app.
  Additive optional fields are fine; renames and removals are not.
- **Cache format changes** bump `CACHE_VERSION` and the `scan-vN.json`
  filename together; old caches are invalidated, never migrated.
- **UTC vs local**: anything social or comparable stays on UTC days.
  Personal, single-user views may re-bucket into the local timezone, always
  from the stored UTC hour instants.
- **Size discipline**: no new runtime dependencies in the app without
  discussion. The whole point is a sub-1MB download.

## Adding support for a new tool's logs

The engine treats each source as a scanner that yields priced-unit
`Entry` values (date, hour, model, speed, usage). Look at `src/claude.rs`
and `src/codex.rs`: implement `scan_file` with dedupe hashes and
cache-dependency tracking, wire it in `src/scan.rs`, and add fixture-based
tests like the existing ones.

## Reporting issues

Include the output of `brrrn --json | head -40` (redact anything you like;
it contains no prompts by design) and, for app issues, the macOS version.

## Security

The hub is internet-facing. If you find a vulnerability in `hub/`, please
report it privately via GitHub security advisories rather than a public
issue.
