# brrrn agent guide

Canonical instructions for coding agents (Codex, Claude Code, and friends)
working in this repo. `CLAUDE.md` imports this file; keep everything here.

brrrn is "WHOOP for token burn": a Rust engine that prices local Claude
Code / Codex logs, a native SwiftUI menu bar app, and a Cloudflare Worker
hub for private friend leaderboards. Product decisions live in `PRD.md`.

## Layout

| Path | What | Stack |
|---|---|---|
| `src/` | Engine: log scanning, dedupe, pricing, UTC day/hour aggregation, incremental cache, social CLI | Rust |
| `app/` | Menu bar app (`BrrrnBar`) + testable core (`BrrrnCore`) | Swift 6, SwiftUI, Charts, macOS 14+ |
| `hub/` | Pit hub: Worker + KV + one Coordinator Durable Object | JS, plain Node tests |
| `docs/screenshots/` | README gallery, generated from code (never hand-captured) | — |
| `.agents/skills/` | Task recipes (verify, screenshots, release, deploy-hub) | — |

## Build and test

```sh
cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
cd hub && npm test
cd app && swift test
cd app && ./scripts/build-app.sh && ./scripts/measure-size.sh   # release bundle + 2MB budget
```

CI (`.github/workflows/ci.yml`) runs exactly this. Run `cargo fmt` after any
Rust change; forgetting it is the most common CI failure. All three suites
must be green before pushing to `main` (there is no PR gate; `main` is live).

## Non-negotiable conventions

- **Frozen JSON schema**: `brrrn --json` output is decoded by the app.
  Additive optional fields only; never rename or remove.
- **Cache format changes** bump `CACHE_VERSION` in `src/cache.rs` AND the
  `scan-vN.json` filename in `src/main.rs` together. Old caches are
  invalidated, never migrated.
- **UTC vs local**: anything social or comparable (calendar, streaks,
  boards, records-by-day) stays on UTC days. Personal views may re-bucket
  into the local timezone, always derived from the stored UTC hour instants.
- **Identity model**: handles are permanent auto-generated IDs (day records
  key on them); display names are the editable human layer. Never make a
  handle mutable.
- **Size discipline**: the compressed app download must stay under the 2 MB
  CI budget. No new runtime dependencies without discussion.
- **SwiftUI layout**: full-page views must pin to the top and fill the
  window explicitly; `Color.clear` spacers need constraints on BOTH axes
  (an unbounded axis makes the whole row greedy and centers the page).
- **MenuBarExtra**: never present a `.sheet` (it steals key status and
  closes the menu); navigate by swapping inline pages.
- **Screenshots are code**: after any visible UI change, regenerate the
  gallery (see `.agents/skills/screenshots/SKILL.md`).
- **Conventional commits**: `feat(app):`, `fix(core):`, `feat(hub):`,
  `docs:`, `style:`. Scopes: `core` (Rust), `app` (Swift), `hub` (Worker).
- **No em dashes** in any prose, docs, or comments.

## Skills

Step-by-step recipes for recurring tasks live in `.agents/skills/<name>/SKILL.md`
(Claude Code discovers them via the `.claude/skills` symlink; other agents:
read them directly):

- `verify` — runtime verification against real data on all three surfaces
- `screenshots` — regenerate the README gallery / render your own data
- `release` — cut and publish a versioned release, end to end
- `deploy-hub` — deploy the Worker and smoke-test it live

## Testing philosophy

Behavior lives behind tests: parsing, dedupe, pricing, calendar windows,
streaks, timezone re-bucketing, cache invalidation, Worker routes, and
frozen schemas. View logic goes in `BrrrnCore` so it is testable without
rendering. The hub suite runs on plain Node with a Map-backed KV mock; no
network in any test.
