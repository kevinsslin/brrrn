---
name: verify
summary: Runtime verification recipes for brrrn surfaces
---

# Verify brrrn

## Rust CLI

Build once, then drive the compiled binary against real local logs:

```sh
cargo build --release
./target/release/brrrn --period week
./target/release/brrrn --period month --json | jq '{period,tz,windows,by_source,streak}'
./target/release/brrrn --period fortnight  # expect exit 2 and a useful error
./target/release/brrrn --tz mars           # expect exit 2 and a useful error
```

Confirm calendar windows use UTC, `week` begins Monday, `month` begins on day
1, and streak remains full-history even when the report is period-filtered.

## Hub

Run `npx wrangler dev --local --port 0`, create a pit through HTTP, join,
submit daily aggregates, then read board and member endpoints. Probe wrong
secret, duplicate handle, malformed payload, and unknown routes.

## Menu bar

Run `swift run BrrrnBar`, open the flame menu, inspect personal cost/model
hover detail and the pit board. Click a member to reach the 14-day detail view.
