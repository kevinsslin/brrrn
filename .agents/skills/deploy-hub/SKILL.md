---
name: deploy-hub
description: Deploy the Cloudflare Worker hub and smoke-test it against the live URL.
---

# Deploy the hub

```sh
cd hub
npm test                 # never deploy red
npx wrangler deploy      # prints the live URL
```

First-time setup only: `npx wrangler kv namespace create BRRRN_KV` (ID goes
in `wrangler.toml`), and the account needs a workers.dev subdomain (created
on first dashboard visit). Optional gate for shared hubs:
`npx wrangler secret put PIT_CREATE_TOKEN`.

## Smoke test (live)

```sh
HUB=https://<worker>.workers.dev
CODE=$(curl -s -X POST $HUB/pit -H 'content-type: application/json' -d '{"name":"smoke"}' | jq -r .code)
curl -s -X POST $HUB/pit/$CODE/join -H 'content-type: application/json' -d '{"handle":"smokey","secret":"s1","display_name":"Smoke"}'
curl -s -X POST $HUB/pit/$CODE/submit -H 'content-type: application/json' -d '{"handle":"smokey","secret":"s1","machine_id":"m1","days":[{"date":"2026-01-01","tokens":1000,"cost_usd":42.5,"claude_usd":30,"codex_usd":12.5}]}'
curl -s $HUB/pit/$CODE/board | jq .
curl -s -o /dev/null -w '%{http_code}\n' -X POST $HUB/pit/$CODE/submit -H 'content-type: application/json' -d '{"handle":"smokey","secret":"wrong","machine_id":"m1","days":[]}'  # expect 401
```

Then clean up the smoke pit:

```sh
npx wrangler kv key delete "pit:$CODE" --namespace-id <id> --remote
npx wrangler kv key delete "member:$CODE:smokey" --namespace-id <id> --remote
npx wrangler kv key delete "day:$CODE:smokey:m1:2026-01-01" --namespace-id <id> --remote
```

Known wrinkle: the very first request after deploying a new Durable Object
class can fail once with a Cloudflare 1104 while the DO cold-starts; retry.
