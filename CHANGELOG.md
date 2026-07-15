# Changelog

All notable changes to brrrn are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/).

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

[0.1.0]: https://github.com/kevinsslin/brrrn/releases/tag/v0.1.0
