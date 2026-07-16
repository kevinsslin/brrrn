# Changelog

All notable changes to brrrn are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/).

## [0.1.2] - 2026-07-17

Cost-accounting audit release. The pricing and token math was audited end
to end (headless Codex, gpt-5.6-sol at x-high reasoning, adversarially
reviewed before merge); every fix below carries a test that fails without
it. On the audited corpus the corrections add about **$2,028 of previously
undercounted all-time burn**, dominated by priority-tier pricing.

### Fixed

- **Priority/flex service tiers now use LiteLLM's tier-specific rates**
  (`input_cost_per_token_priority` and friends) instead of standard rates.
  Priority usage was undercounted by roughly 2x.
- Claude records with `usage.iterations` (fallback and compaction) are
  billed per iteration; free pre-output refusals are excluded.
- Partial streaming records no longer beat later finalized usage with the
  same identity; log traversal prefers the newest file so resumed sessions
  keep the richest copy.
- Streak threshold comparisons are stable at microdollar precision across
  Rust, Swift, and the hub, so fifty $0.10 entries cannot sum to
  $4.999999... and break a streak.
- Hub cost rounding preserves decimal half-ties.
- App model-merge keys can no longer collide across source/model/variant;
  an ongoing streak that ties the historical record now shows as current.

### Changed

- App refresh runs one engine scan instead of four (warm refresh 0.22s to
  0.13s wall, cold 26.3s to 6.0s CPU) via an additive `models_by_period`
  JSON field, with a fallback for older engines.
- Cache format v7 (one-time full rescan on first run).

## [0.1.1] - 2026-07-16

### Added

- Pits can be renamed by any member, from the pencil next to the pit
  name in the app or `brrrn pit title <code> <name>` (pits deliberately
  have no admin tier; the trust model is your friends)
- Today's top three wear podium medals on the board

### Changed

- Handles are now auto-generated, collision-proof IDs (48 random bits);
  people set a display name instead. `pit join` no longer requires
  `--as` (it remains available for picking your own ID), and the app's
  setup page asks first-time joiners for their name only. This removes
  the one unhandled conflict: joining a pit where someone else had
  already claimed your handle.
- Joining without a display name prints a hint about `brrrn pit rename`.

## [0.1.0] - 2026-07-16

First public release. 🔥

### Engine (Rust CLI)

- Local scanning of Claude Code (`~/.claude/projects`) and Codex
  (`~/.codex/sessions`) logs with resumed-session and forked-rollout dedupe
- API-list-price costing via the cached LiteLLM table, aware of cache tiers
  (read / 5-minute / 1-hour writes) and reasoning tokens
- UTC calendar bucketing by day and hour; ISO weeks; calendar months;
  $5/day streaks
- Per-file incremental cache: ~8s cold on 8.9 GB of history, ~0.1s warm
- Variant identity: reasoning effort and fast mode (Claude fast, Codex
  priority tier) tracked per entry
- Social CLI: `pit new / join / rename / show`, `submit` (backfill +
  daily), `flex`, `config set-hub`
- `--json` machine-readable output (frozen schema) that feeds the app

### Menu bar app (Swift, macOS 14+)

- Today's burn in the bar; Me / Pits pages that fit the window without an
  outer scrollbar
- Analytics tabs, equal height: burn calendar with side detail panel,
  14/30/90-day trend, hour-of-day rhythm in your local timezone (UTC
  toggle), and personal records (biggest hour, biggest day, longest
  streak) with live SET TODAY / ONGOING badges
- By-model costs for today / week / month with hover token detail and a
  fast/standard cost split
- Private pit boards: deterministic emoji avatars, weekly-king crown,
  member drill-down with 16-week calendar and last-active line
- In-app pit setup: start or join with one pasted invite
  (`code@hub`), optional editable display name on a permanent handle
- Screenshot generator (`BrrrnBar --screenshots`) renders the README
  gallery from the real views with seeded demo data

### Hub (Cloudflare Worker + KV + Durable Object)

- Invite-code pits with atomic handle claims, per-machine day records,
  and multi-machine aggregation
- Board aggregation: today / ISO week / calendar month, streaks, weekly
  per-model detail
- Display names stored per member; same-secret re-join is a rename
- Optional `PIT_CREATE_TOKEN` gate for shared hubs
- Rate limiting, request-body deadlines and per-client reader caps, and a
  coordinator Durable Object serializing mutations
- v2 relationship/invitation API (direct friends, named groups,
  single-use invitation tokens) implemented and tested server-side;
  client adoption is on the roadmap

### Known limitations

- The app bundle is unsigned; macOS requires right-click → Open on first
  launch. Signed and notarized releases are planned.
- Fast mode / priority tier is displayed but priced at standard rates
  until public tier pricing exists.
- Models without a public LiteLLM price show `n/a` cost.

[0.1.2]: https://github.com/kevinsslin/brrrn/releases/tag/v0.1.2
[0.1.1]: https://github.com/kevinsslin/brrrn/releases/tag/v0.1.1
[0.1.0]: https://github.com/kevinsslin/brrrn/releases/tag/v0.1.0
