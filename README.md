# brrrn

**WHOOP for token burn.** See the API-value cost of every token you burn in
Claude Code and Codex, then compare today, this week, and this month with a
private group of friends.

No global leaderboard. No accounts. No prompts leave your Mac.

## What is included

- **Rust CLI and engine**: local Claude Code + Codex log scanning, model/cache
  aware pricing, UTC calendar days, ISO weeks, calendar months, and a $5/day
  streak.
- **Native macOS menu bar app**: today's cost in the bar, cost-first model
  breakdowns, hover input/output tokens, private friend rankings, and clickable
  14-day member history.
- **Private pit hub**: Cloudflare Worker + KV, with one tiny Durable Object
  coordinator for atomic joins, rate limits, and concurrent submissions. Invite
  codes connect a group; first submit backfills history, later submits update
  today and yesterday.
- **Sharing**: `brrrn flex` opens a pre-filled post with today's personal and
  crew burn.

Full product decisions and API schemas live in [PRD.md](PRD.md).

## CLI quick start

```sh
cargo build --release

./target/release/brrrn
./target/release/brrrn --period today
./target/release/brrrn --period week
./target/release/brrrn --period month
./target/release/brrrn --daily
./target/release/brrrn --json
```

Days use UTC by default so friends in different timezones compare the same
calendar day. Personal reports can opt into local calendar days:

```sh
brrrn --tz local
```

A full 8.9GB history scan takes about 8 seconds once. The per-file incremental
cache brings typical warm scans to roughly 0.1 seconds.

## macOS menu bar app

```sh
cargo build --release
cd app
swift test
./scripts/build-app.sh
open dist/BrrrnBar.app
```

The app is native SwiftUI (`MenuBarExtra`, macOS 14+) and runs without a Dock
icon. It refreshes local usage every minute and after filesystem changes. Every
five minutes it submits fresh daily aggregates and pulls the latest pit board.

For development:

```sh
cd app
BRRRN_BIN=../target/release/brrrn swift run BrrrnBar
```

## Add friends

A friend group is called a **pit**. Membership is intentionally simple: share a
server-generated invite code in your group chat.

### 1. Deploy the hub

```sh
cd hub
npm test
npx wrangler kv namespace create BRRRN_KV
# put the returned namespace ID in hub/wrangler.toml
npx wrangler deploy
```

### 2. Configure and create a pit

```sh
brrrn config set-hub https://brrrn-hub.<account>.workers.dev
brrrn pit new --name "Taipei Burn Club"
```

Share the printed code. Each person joins with their own handle:

```sh
brrrn pit join ember-fox-x7kq --as kevin
brrrn submit
```

### 3. View and drill down

```sh
brrrn pit
brrrn pit show kevin
brrrn flex --no-open
```

The first submit backfills all available daily history (chunked at 400 days per
request). Later submits send today and yesterday. Multiple Macs get distinct
machine IDs and add together instead of overwriting each other.

## What gets uploaded

Only these daily aggregates leave the machine:

- pit code and handle
- random machine ID
- UTC date
- token count and API-value USD cost
- Claude/Codex cost split
- per-model input tokens, output tokens, and cost

Never uploaded: prompts, responses, file paths, repository names, session
content, or timestamps finer than a UTC day.

This is an honor-system leaderboard for people you know. It does not attempt to
prevent a friend from submitting fake numbers.

## Data sources

- Claude Code: `~/.claude/projects/**/*.jsonl`. Assistant usage records include
  input/output tokens, 5-minute and 1-hour cache creation, cache reads, model,
  and speed. Resumed-session copies are deduped by message/request identity.
- Codex: `~/.codex/sessions/**/*.jsonl`. Cumulative `token_count` events are
  converted into deltas and attributed to the latest model/reasoning effort.
  Forked rollout replays are deduped by timestamp and cumulative totals.

## Pricing and interpretation

Prices are API list-price equivalents from
[LiteLLM's pricing table](https://github.com/BerriAI/litellm), cached at
`~/Library/Caches/brrrn/litellm_prices.json`.

If you use Claude Max or ChatGPT Pro, the number is not money charged to your
card. Read it as **API value extracted from the subscription**.

Known pricing gaps:

- Codex multi-agent child sessions sometimes omit their model and appear as
  `unknown` (tokens count, cost does not).
- Models with no public LiteLLM price, such as `gpt-5.3-codex-spark` and
  `codex-auto-review`, show `n/a` cost.
- Claude fast rows remain separate, but use standard pricing until a distinct
  public fast-mode price is available.

## Development

```sh
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test

cd hub && npm test
cd ../app && swift test && ./scripts/build-app.sh
```

The project uses conventional commits and test-first coverage for parsing,
deduplication, pricing, calendar windows, streak behavior, cache invalidation,
payload building, Worker routes, frozen JSON schemas, formatting, and sorting.

## License

MIT. See [LICENSE](LICENSE).
