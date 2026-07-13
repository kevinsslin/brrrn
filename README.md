# brrrn

Your tokens go brrrn. Local token burn + cost report for Claude Code and
Codex: reads the JSONL session logs both CLIs already write to disk,
aggregates tokens by model and speed/effort, and prices them against
LiteLLM's public pricing table. Fully local: no login, no telemetry, no
network except the optional pricing refresh.

Status: CLI prototype. The end goal is a tiny native macOS menu bar app,
plus a WHOOP-style friends view: everyone's daily burn on one leaderboard.
Full product spec lives in [PRD.md](PRD.md).

## Usage

```sh
cargo build --release
./target/release/brrrn                 # all-time report + today/7d/month summary
./target/release/brrrn --period today  # just today
./target/release/brrrn --daily         # per-day breakdown, last 14 days
./target/release/brrrn --json          # machine-readable output
./target/release/brrrn --tz local      # bucket days in local time instead of UTC
./target/release/brrrn --update-pricing  # refresh pricing table (curl)
```

Days are bucketed in UTC by default so that daily numbers are comparable
across machines and friends in different timezones. Use `--tz local` if you
want calendar days as you experienced them.

## Data sources

- Claude Code: `~/.claude/projects/**/*.jsonl`. Each assistant message has
  `message.usage` with input/output tokens, cache creation (5m/1h ephemeral),
  cache reads, model, and speed. Deduped on (message.id, requestId) because
  resumed sessions copy history into new files.
- Codex: `~/.codex/sessions/**/*.jsonl`. `token_count` events carry cumulative
  session totals; we take deltas and attribute them to the model/effort from
  the most recent `turn_context`. Deduped on (timestamp, totals) to survive
  forked rollouts.

## Pricing

USD costs are API list-price equivalents from
[LiteLLM's pricing table](https://github.com/BerriAI/litellm), cached at
`~/Library/Caches/brrrn/litellm_prices.json`. If you are on a subscription
plan (Claude Max, ChatGPT Pro), read the numbers as "API value burned", not
money actually spent.

Known gaps:
- Codex multi-agent sub-sessions do not record their model; shown as `unknown`.
- `gpt-5.3-codex-spark` and `codex-auto-review` have no public pricing yet.
- Claude fast mode would be priced at standard rates (no public fast pricing
  in LiteLLM yet); rows are still split out by speed so this is visible.

## Roadmap

1. CLI prototype (this)
2. macOS menu bar app: Swift `MenuBarExtra` shell over the same scanner,
   FSEvents incremental updates, today's burn in the bar
3. Friends leaderboard: `brrrn submit` posts daily aggregates (handle, date,
   tokens, cost) to a tiny worker; honor-system, numbers only, UTC days
