# poppycoop-api (Cloudflare Worker)

One worker for the launcher's online features:

- `POST /report` - crash reports, forwarded into a Discord channel (reports.js). The Discord webhook is a
  secret of the worker, it is not in the launcher.
- `POST /v1/...` - friends: friend requests, accept/decline, friend list with online status, chapter and
  room (friends.js), stored in a D1 database (free: 5 M reads / 100 k writes per day).

## Set up (once, on the Cloudflare account that runs poppycoop-relay)

In this folder:

```
npx wrangler login
npx wrangler d1 create poppycoop
```
Copy the `database_id` it prints into `wrangler.toml` (replace `PASTE-THE-ID-FROM-wrangler-d1-create`), then:

```
npx wrangler d1 execute poppycoop --remote --file=schema.sql
npx wrangler deploy
npx wrangler secret put DISCORD_WEBHOOK
```
For the webhook: Discord channel settings -> Integrations -> Webhooks -> New Webhook -> Copy Webhook URL,
paste it when asked.

The worker is then at `https://poppycoop-api.<account>.workers.dev`. The launcher uses
`https://poppycoop-api.poppycoopnet.workers.dev` (same account subdomain as the relay). If the account
subdomain is different, tell us - it is `API_HOST` in launcher/v3/friends_net.h and `REPORT_HOST` in
launcher/v3/crashreport.h.

## Test after deploying

```
curl -A "PoppyCoopLauncher/test" -H "X-Account: 0123456789abcdef" -H "X-Secret: 0123456789abcdef0123456789abcdef" \
     -d name=Test -d tag=12345 https://poppycoop-api.poppycoopnet.workers.dev/v1/hello
```
Answer `OK created` = the friends part works. Crash reports:
```
curl -A "PoppyCoopLauncher/test" -F version=1.5.7 -F chapter=2 -F os="test" -F summary="test report" \
     https://poppycoop-api.poppycoopnet.workers.dev/report
```
Answer `{"success":true,...}` and a message in the channel = working.

## Friends protocol (friends.js)

Headers `X-Account` (16 hex, made by the launcher) and `X-Secret` (32 hex; only its SHA-256 is stored).
Form fields in, text lines out: `OK ...`, `E <code>`, `F <name#tag> <online> <chapter> <room|->`,
`I <name#tag>` (incoming request), `O <name#tag>` (sent, waiting).

| Path | Fields | |
|---|---|---|
| /v1/hello | name, tag, chapter, room, ingame | create/update the account + status (launcher: every 60 s) |
| /v1/list | | friends, incoming, outgoing |
| /v1/request | code | send a request (both asked = friends) |
| /v1/respond | code, accept=1/0 | accept / decline |
| /v1/remove | code | remove a friend / take back a request |

Online = said hello within 120 s. Room and chapter are only shown to friends. Limits: 30 open requests,
30 requests per hour, 200 friends.

## Local test (no account needed)

```
npx wrangler d1 execute poppycoop --local --file=schema.sql
npx wrangler dev --local --port 8787
```
Start the launcher with `POPPYCOOP_API_TEST=127.0.0.1:8787` to use it.

## Limits for crash reports

4 MB per report, 1.5 MB per file, at most 6 per IP per hour, launcher user agent only, mentions neutralised.
If the webhook gets spammed: delete it in Discord, make a new one, `wrangler secret put DISCORD_WEBHOOK` again.
