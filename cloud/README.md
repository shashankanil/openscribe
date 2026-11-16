# OpenScribe Cloud

A Cloudflare Worker that does two jobs:

1. **Sync API** for the OpenScribe desktop app (`/app/login`, `/api/v1/*`). Sync is opt-in.
2. **Remote MCP server** at `/mcp` (Streamable HTTP). Claude, ChatGPT and other MCP clients connect with OAuth 2.1 and dynamic client registration. Google is the identity provider.

The binding contract is [`docs/CONTEXT-API.md`](../docs/CONTEXT-API.md): document shape, the five tools, and the sync endpoints.

| Piece | Implementation |
|---|---|
| Runtime | Cloudflare Workers (TypeScript), `wrangler.jsonc` |
| Storage | D1 (`documents`, `users`, `app_tokens`), with an FTS5 index (`documents_fts`, bm25 ranking, `snippet()`) |
| OAuth server | `@cloudflare/workers-oauth-provider` 1.2 (DCR, PKCE, CIMD, refresh rotation). Grants and tokens live in KV (`OAUTH_KV`) and are stored hashed. |
| MCP | `createMcpHandler` from `agents/mcp/server` with `@modelcontextprotocol/server` (SDK v2). Stateless: no Durable Objects. |
| Identity | Google OpenID Connect (authorization code + PKCE). Users are keyed by Google `sub`. |

## Routes

| Route | Purpose |
|---|---|
| `GET /` | Landing page that explains how to connect |
| `POST /mcp` | Remote MCP endpoint. Needs an OAuth bearer token. |
| `/.well-known/oauth-protected-resource/mcp`, `/.well-known/oauth-authorization-server` | OAuth discovery |
| `POST /register`, `GET+POST /authorize`, `POST /token` | Dynamic client registration, consent, and token exchange |
| `GET /callback` | **The Google redirect URI**, shared by MCP sign-in and app sign-in |
| `GET /app/login?redirect_uri=openscribe://auth&state=…` | Desktop sign-in. Ends at `openscribe://auth?token=…&state=…`. |
| `/api/v1/me`, `/api/v1/documents/batch`, `/api/v1/documents/:id`, `/api/v1/logout`, `/api/v1/account` | Sync API. Needs an app token. |

## Deploy

You need a Cloudflare account and a Google Cloud project. Run everything from `cloud/`.

### 1. Install and log in

```sh
cd cloud
npm install
npx wrangler login
```

### 2. Create the D1 database and the KV namespace

```sh
npx wrangler d1 create openscribe
npx wrangler kv namespace create OAUTH_KV
```

Paste the printed `database_id` into `d1_databases[0].database_id` in `wrangler.jsonc`. Paste the KV `id` into `kv_namespaces[0].id`.

### 3. Pick the public URL

Every MCP token is bound to `${PUBLIC_URL}/mcp`, and the Google redirect URI is `${PUBLIC_URL}/callback`, so get this right before going further.

- **workers.dev:** `https://openscribe-cloud.<your-subdomain>.workers.dev`. Your subdomain is under Workers & Pages → Account details in the Cloudflare dashboard.
- **Custom domain:** add `"routes": [{ "pattern": "cloud.example.com", "custom_domain": true }]` to `wrangler.jsonc` and use `https://cloud.example.com`.

Set `vars.PUBLIC_URL` in `wrangler.jsonc` to that origin, with no trailing slash. Optionally, also change `vars.APP_DOWNLOAD_URL`.

### 4. Create the Google OAuth client

In [Google Cloud console](https://console.cloud.google.com/):

1. **APIs & Services → OAuth consent screen** (Google Auth Platform → Branding / Audience):
   - User type: **External**. Add an app name and support email.
   - Scopes (Data access): `openid`, `.../auth/userinfo.email`, `.../auth/userinfo.profile`. These are all non-sensitive, so Google doesn't need to verify the app.
   - Audience: while the app is in **Testing**, only listed test users can sign in. Click **Publish app** to allow any Google account.
2. **APIs & Services → Credentials → Create credentials → OAuth client ID**:
   - Application type: **Web application**
   - **Authorized redirect URIs:**
     - `https://<PUBLIC_URL host>/callback` (production, for example `https://openscribe-cloud.<your-subdomain>.workers.dev/callback`)
     - `http://localhost:8788/callback` (only if you'll run `wrangler dev`. A separate dev client is cleaner.)
   - Authorized JavaScript origins aren't needed.
3. Copy the **Client ID** and **Client secret**.

### 5. Set secrets

```sh
npx wrangler secret put GOOGLE_CLIENT_ID
npx wrangler secret put GOOGLE_CLIENT_SECRET
npx wrangler secret put COOKIE_ENCRYPTION_KEY   # paste the output of: openssl rand -hex 32
# Optional: only accept accounts from one Google Workspace domain
npx wrangler secret put HOSTED_DOMAIN
```

If the Worker doesn't exist yet, `wrangler secret put` offers to create it. Answer yes.

`COOKIE_ENCRYPTION_KEY` signs the "remember this client" consent cookie. It must be at least 32 characters.

### 6. Apply migrations and deploy

```sh
npx wrangler d1 migrations apply openscribe --remote
npx wrangler deploy
```

### 7. Smoke test

```sh
curl -s https://<host>/.well-known/oauth-protected-resource/mcp   # resource must equal https://<host>/mcp
curl -si https://<host>/mcp -X POST | head -5                       # 401 with WWW-Authenticate … resource_metadata=…
npx @modelcontextprotocol/inspector@latest                          # connect to https://<host>/mcp, sign in, list tools
```

Open `https://<host>/` in a browser to see the landing page.

## Connect an assistant

The server URL is always `https://<host>/mcp`. Every client goes through the same steps: a consent page on this Worker, then Google sign-in.

- **claude.ai (web):** Settings → Connectors → **Add custom connector**. Name it `OpenScribe`, set the URL to `https://<host>/mcp`, click Add, then Connect. On Team and Enterprise plans, an owner adds the connector under Admin settings → Connectors first.
- **Claude Desktop:** Settings → Connectors → Add custom connector, the same way as claude.ai. Connectors sync with your Claude account. Older builds without remote connectors can use a bridge instead: in `claude_desktop_config.json`, add `{"mcpServers": {"openscribe": {"command": "npx", "args": ["mcp-remote", "https://<host>/mcp"]}}}`.
- **Claude Code:**
  ```sh
  claude mcp add --transport http openscribe https://<host>/mcp
  ```
  Then run `/mcp` in Claude Code, choose `openscribe`, and pick **Authenticate**.
- **ChatGPT:** Settings → Apps & Connectors → Advanced settings → turn on **Developer mode**, then **Create** a connector. Set the MCP server URL to `https://<host>/mcp` and Authentication to **OAuth**, then sign in. `search` and `fetch` follow the ChatGPT connector conventions, so deep research works as well. Which plans offer this depends on OpenAI.

## Desktop app integration

The app opens this URL in the browser:

```
https://<host>/app/login?redirect_uri=openscribe://auth&state=<random, 8-512 chars of [A-Za-z0-9._~-]>
```

Once the user signs in with Google, the browser receives a `302` to `openscribe://auth?token=osk_…&state=<same state>`. If the user cancels, the redirect carries `?error=access_denied&state=…` instead. The app must check that `state` matches what it sent. It then sends `Authorization: Bearer osk_…` on every `/api/v1` call. Tokens are opaque, stored server-side only as SHA-256 hashes, and don't expire. `POST /api/v1/logout` revokes one.

`POST /api/v1/documents/batch` returns `{ accepted, skipped, errors }`. `errors` lists entries that failed validation, as `{ index, id?, error }`. Those entries are skipped, and the rest of the batch is still applied.

## Local development

```sh
cp .dev.vars.example .dev.vars    # fill in a dev Google client with http://localhost:8788/callback
npx wrangler d1 migrations apply openscribe --local
npx wrangler dev                  # http://localhost:8788
```

The consent and login cookies use the `__Host-` prefix, which requires the `Secure` attribute. Chrome and Firefox accept that on `http://localhost`. Safari may not.

## Tests

```sh
npm test            # vitest + @cloudflare/vitest-plugin (workerd + local D1/KV)
npm run typecheck
npx wrangler deploy --dry-run
```

The tests apply the migrations to a local D1 and cover the following:

- batch upsert semantics: newer, older, same timestamp, tombstone, and resurrection
- FTS ranking and kind and limit filters
- user isolation
- every MCP tool function
- app-token auth, including missing, unknown and revoked tokens
- `/app/login` redirect validation and the cookie-bound state round-trip, with Google mocked
- body limits
- account deletion
- a full end-to-end flow: dynamic registration → consent → Google (mocked) → `/token` → `/mcp` `tools/list` and `tools/call`

## Security notes

- **Scoping:** every SQL query filters by the user id taken from the verified token. The MCP tools only see `deleted = 0` rows. A tombstone wipes the stored content and keeps only the id, kind and timestamps.
- **App login:** only the exact string `openscribe://auth` is accepted as `redirect_uri`. Anything else gets a `400` page and no redirect. The app's `state` stays server-side in KV under a random nonce that expires in 10 minutes. That nonce is the Google `state`, and it is bound to the browser by a `__Host-` HttpOnly cookie. The callback needs both the cookie and the KV record, and each record works once. This blocks login CSRF and token injection.
- **MCP OAuth:** consent is per client, the consent page can't be framed, and the forms are bound to the browser. The upstream `state` is created only after consent and is bound to the browser too (library helpers). PKCE is used both with MCP clients and with Google.
- **Account deletion:** `DELETE /api/v1/account` revokes every OAuth grant (`listUserGrants` + `revokeGrant`), then deletes the user's documents, app tokens and user row.
- **Not included yet:** rate limiting. Add a Cloudflare rate-limiting rule on `/api/v1/*` and `/register` before a wide launch. KV TTLs expire OAuth records on their own; for extra cleanup you can call `purgeExpiredData()` from a Cron Trigger.
