# OSRS Wiki feedback Worker

Cloudflare Worker that replaces the dead GCP Cloud Function for in-app feedback.

Apps `POST` JSON to **`/createGithubIssue`**. The Worker creates a GitHub Issue with a server-side fine-grained PAT (`GITHUB_TOKEN`). The token never ships in Android/iOS clients.

| `platform` | Target repo |
| --- | --- |
| `ios` | `osrswiki/osrswiki-ios` |
| anything else / omitted (Android clients today omit it) | `osrswiki/osrswiki-android` |

## Request

```http
POST /createGithubIssue
Content-Type: application/json
```

```json
{
  "title": "string (required)",
  "body": "string (required)",
  "labels": ["bug"],
  "platform": "android",
  "appVersion": "1.2.3",
  "distribution": "play"
}
```

Compatible with existing clients:

- Android `CloudFunctionIssueRequest(title, body, labels?)`
- iOS `osrsCloudFunctionIssueRequest(title, body, labels?, platform: "ios")`

## Response

Success `200`:

```json
{ "message": "Issue created successfully.", "url": "https://github.com/osrswiki/osrswiki-android/issues/N" }
```

| Status | Meaning |
| --- | --- |
| 400 | Missing/empty title or body, or invalid JSON |
| 413 | Payload too large |
| 429 | Per-IP rate limit |
| 405 | Wrong method / path |
| 500 / 502 | Misconfigured secret or GitHub failure |

## Hardening (v1)

- Reject empty title/body; cap title (200) and body (8000); max JSON ~32 KiB
- In-memory per-IP rate limit (~8 requests / 15 minutes per isolate). Fine for free-tier v1; not a global durable store
- CORS: `Access-Control-Allow-Origin: *` for `POST` / `OPTIONS` only (native apps usually skip CORS)
- **Turnstile deferred** — see below. Rate limit is the spam control for v1

### Optional: Cloudflare Turnstile

When in-app forms can supply a Turnstile token without hurting UX:

1. Create a Turnstile widget in the Cloudflare dashboard
2. `npx wrangler secret put TURNSTILE_SECRET_KEY`
3. Extend `src/index.js` to verify `turnstileToken` (siteverify) before calling GitHub
4. Point Android/iOS (or a tiny WebView) at the Turnstile site key

Until then, keep the rate limit tight and close obvious spam issues.

## Prerequisites (human / agent on main)

1. **Node.js + npm** on the machine (`brew install node` if missing)
2. **Cloudflare account** with Workers enabled (free tier is enough)
3. **Wrangler login:** `npx wrangler login` (opens browser; OAuth to Cloudflare)
4. **Fine-grained GitHub PAT** (`GITHUB_TOKEN`):
   - Resource owner: `osrswiki` (or the account that owns both public app repos)
   - Repository access: **only** `osrswiki/osrswiki-android` and `osrswiki/osrswiki-ios`
   - Permissions: **Issues: Read and write** (Contents not required)
   - Do **not** commit the token. Do **not** put it in app binaries or `.env` tracked by git

## Deploy

```bash
cd tools/feedback-worker
npm install
npx wrangler login          # once per machine / until token expires
npx wrangler secret put GITHUB_TOKEN   # paste PAT at prompt (interactive)
npx wrangler deploy
```

Record the printed `*.workers.dev` URL (or custom route) for Task 3 app client swap.

Local dry-run (no GitHub write unless `.dev.vars` has `GITHUB_TOKEN`):

```bash
# tools/feedback-worker/.dev.vars  (gitignored)
# GITHUB_TOKEN=ghp_...
npx wrangler dev
```

## Smoke test (only after deploy + secret)

```bash
WORKER_URL="https://osrswiki-feedback.<account>.workers.dev"
curl -sS -X POST "$WORKER_URL/createGithubIssue" \
  -H 'content-type: application/json' \
  -d '{"title":"worker smoke — delete me","body":"throwaway smoke from feedback-worker","labels":["feedback"],"platform":"android","appVersion":"smoke"}'
```

Confirm the issue on `osrswiki/osrswiki-android`, then:

```bash
gh issue close <N> -R osrswiki/osrswiki-android --comment "smoke closed"
```

## Ops notes

- Worker name: `osrswiki-feedback` (`wrangler.toml`)
- Secret name: `GITHUB_TOKEN`
- Non-secret var: `GITHUB_OWNER=osrswiki`
- Rotate the PAT in GitHub → `npx wrangler secret put GITHUB_TOKEN` again
- Tail logs: `npx wrangler tail` (logs must never include the token; the Worker does not print it)

## Out of scope here

- Android / iOS client URL swap → Task 3
- Play / foss flavor wiring → Tasks 4–5
- Store deploy
