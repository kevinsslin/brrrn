# brrrn PRD

Version 0.1, 2026-07-14. Owner: Kevin. Status: draft, pre-commit.

## One-liner

WHOOP for token burn. A tiny macOS menu bar app (plus CLI) that shows how
much AI you and your friends burned today, priced in USD, entirely from
local logs. No accounts, no global leaderboard, just your crew around a fire.

## Problem and positioning

Existing tools answer "how much quota do I have left" (CodexBar) or "how much
did I spend, alone, in a terminal" (ccusage). Nobody does the social loop:
seeing your friends' daily burn the way WHOOP shows a team's recovery scores.
Burn is a flex, not a worry. The product is built around that emotion.

Non-goals (explicit):
- Global/public leaderboard. Private groups only.
- Anti-cheat. Trust model is "your friends". Submissions are honor-system.
- Accounts, OAuth, email. Identity is a handle plus a locally stored secret.
- Rate-limit/quota tracking. CodexBar owns that space.

## Core concepts

- **Burn**: tokens consumed, priced at API list-price equivalents from the
  LiteLLM pricing table. On subscription plans this reads as "value
  extracted", which is the fun number.
- **Pit** (the group): a private leaderboard. Membership = knowing the join
  code. Like a WHOOP team or a private Discord invite.
- **UTC days**: all day bucketing is UTC so every member's "today" is the
  same day. Local-time view stays available in the CLI (`--tz local`) for
  personal use only; anything social is UTC.

## Time windows

Calendar-based, WHOOP-style, all in UTC:

| window     | definition                              |
|------------|-----------------------------------------|
| today      | current UTC date                         |
| this week  | ISO week, Monday 00:00 UTC to now        |
| this month | 1st of current month 00:00 UTC to now    |
| all time   | first record to now                      |

Rolling 7d/30d views are dropped from the social surfaces (they made "who
won this week" ambiguous). The CLI keeps them only if free to implement.
Calendar month grouping is cheap: days are already bucketed as UTC dates,
grouping by year-month is a string prefix.

## Product surfaces

### 1. CLI (v0, exists)

Rust binary. Scans `~/.claude/projects` and `~/.codex/sessions`, aggregates
by model and speed/effort, prices via cached LiteLLM table, prints tables or
`--json`. 8.9GB of history scans in ~8s cold; incremental cache (planned)
brings repeat runs to milliseconds.

New subcommands for the social layer:

```
brrrn pit new [--name "台北燒錢俱樂部"]   # create pit, prints join code
brrrn pit join <code> --as <handle>       # join, generates local secret
brrrn pit                                 # board: today / this week / this month
brrrn pit show <handle>                   # drill into one member
brrrn submit                              # push aggregates (auto-backfills)
brrrn flex                                # share card / tweet intent (P2)
```

### 2. Menu bar app (v1)

Native Swift `MenuBarExtra` shell over the Rust engine (no Electron). The
bar shows today's burn: `🔥 $4,799`. Dropdown, top to bottom:

1. **Me**: today / this week / this month, split claude vs codex, top model.
2. **Pit board**: members ranked by today's burn, this-week totals alongside.
3. **Drill-down**: clicking a member opens a detail view: 14-day sparkline,
   this week vs last week, top model, current streak. This satisfies
   "可以點進去看".

Display rule, everywhere: **cost is the primary number; hover reveals
per-model input/output tokens.** Raw token counts are not comparable across
models (1M Haiku tokens is not 1M Fable tokens), so cost carries the
ranking and tokens are detail. Applies to the me-section model list, the
pit board rows, and drill-down views.

Refresh: FSEvents on the two log dirs for own numbers (near-realtime);
poll the pit board every 5 minutes.

### 3. Sharing (P2, deliberately cheap)

Sharing is a growth feature, not core. Two stages:
- **P2a `brrrn flex`**: compose a text summary ("I burned $4,799 of tokens
  today 🔥 my crew burned $6,342") and open a pre-filled tweet intent URL.
  Zero infrastructure, ~30 lines.
- **P2b image card**: Spotify-Wrapped-style PNG rendered locally (weekly
  recap, model breakdown). Ship only if P2a shows demand.

## Data flow: hub, not sync

Raw logs never leave the machine. There is no peer-to-peer sync and no
mutual replication. Each client:

1. Scans its own logs locally (full detail stays local).
2. Reduces to per-UTC-day aggregates: date, tokens, cost, claude/codex cost
   split, and a per-model breakdown (input/output tokens + cost per model)
   to power hover detail on boards. Roughly a hundred bytes per day.
3. Pushes them to the worker. **First submit backfills all history** (240
   days is ~25KB, one POST), answering "好友過去的資料怎麼上來": their client
   computes the past from their own logs and uploads it on join.
4. Every later submit sends today and yesterday only (yesterday catches
   writes that land near the UTC midnight boundary).
5. Boards are read from the worker, never from peers.

Multi-machine: each install generates a `machine_id`. Submissions are stored
per (handle, machine, date); the board sums across machines and re-submits
from the same machine overwrite that machine's row. Laptop plus desktop
therefore adds up instead of double-counting or clobbering.

## Backend: Cloudflare Worker + KV

One worker, ~150 lines, free tier is plenty (a pit of 10 friends writes a
few KB/day).

Endpoints:

```
POST /pit                    -> { code }            body: { name? }
POST /pit/:code/join         -> { ok }              body: { handle, secret }; 409 if handle taken
POST /pit/:code/submit       -> { ok, days_stored } body: { handle, secret, machine_id, days: [
                                                      { date, tokens, cost_usd, claude_usd, codex_usd,
                                                        models: { "<model>": { input_tokens, output_tokens, cost_usd } } } ] }
GET  /pit/:code/board        -> { name, code, members: [
                                   { handle, today_usd, week_usd, month_usd, streak_days,
                                     top_model, models_week: [{ model, input_tokens, output_tokens, cost_usd }] } ] }
                                 sorted by today_usd desc; week/month are calendar UTC; streak at $5
GET  /pit/:code/member/:h    -> { handle, days: [{ date, tokens, cost_usd }] }
```

KV schema (key -> value):

```
pit:<code>                        -> { name, created_at }
member:<code>:<handle>            -> { secret_hash, joined_at }
days:<code>:<handle>:<machine_id> -> { "<date>": { t, c, cc, cx, models } , ... }
ratelimit:join:<ip>               -> counter with TTL
```

Board reads list `days:<code>:*` by prefix and merge in the worker. If pits
outgrow KV list performance, migrate to D1; the API does not change.

## Identity and trust

- Join code: generated server-side, is the KV primary key, so collisions are
  impossible by construction (regenerate on the rare create-time hit).
  Format `word-word-xxxx` (two words plus 4 random alphanumerics), space on
  the order of billions, so codes cannot be enumerated; worker rate-limits
  join attempts per IP as a second layer.
- Pit display name is separate from the code, need not be unique.
- Handle: unique within a pit, claimed at join with a client-generated
  secret (stored in `~/.config/brrrn/`, hashed server-side). Prevents
  accidental or prank overwrites; that is its entire job.
- No kick/ban/admin. A compromised pit is abandoned and recreated.

## Privacy

What leaves the machine, exhaustively: pit code, handle, machine_id (random),
UTC date, token count, USD cost, claude/codex cost split, top model name.
Never: prompts, file paths, repo names, session content, timestamps finer
than a day. This list goes in the README verbatim.

## Distribution

- CLI: Homebrew tap (`brew install kevinslin/tap/brrrn`), later homebrew-core;
  `cargo install brrrn` (name verified available on crates.io 2026-07-14).
- Menu bar app: GitHub Releases with Developer ID-signed, notarized DMG
  (universal binary); Homebrew cask; Sparkle auto-update.
- License: MIT. README leads with a screenshot, one-line install, and the
  privacy list.

## Milestones

1. **M0 (done)**: CLI scanner, pricing, UTC days, `--json`.
2. **M1**: incremental cache; `this week`/`this month` windows replace
   rolling ones in default output.
3. **M2**: worker + `pit new/join/submit/board/show`. Two-person test with a
   real friend.
4. **M3**: menu bar app consuming `brrrn --json` and the board API.
5. **P2**: `brrrn flex` text share; image cards only if demand shows.

## Resolved decisions

- **Streak**: consecutive UTC days with burn >= $5.00. $10 punishes normal
  light days; $5 means "actually used it today". Single constant on client
  and worker; per-pit override is a possible later setting. An incomplete
  "today" below $5 does not break a streak until the UTC day ends.
- **Cost-primary display** with hover token detail (see menu bar section).

## Open questions

- Submit cadence: piggyback on menu bar refresh vs launchd timer for
  CLI-only users.
- Fable/Opus fast-mode pricing once published: needs a (model, speed)
  pricing key, engine already groups by speed.
