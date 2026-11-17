import { env, exports } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { pkceChallenge, randomToken } from "../src/crypto";
import { GOOGLE_TOKEN_URL } from "../src/google";
import { BASE, makeDoc, resetDb, seedUserWithToken } from "./helpers";

const worker = exports.default;
const call = (path: string, init?: RequestInit) => worker.fetch(new Request(`${BASE}${path}`, { redirect: "manual", ...init }));
const bearer = (token: string, init: RequestInit = {}): RequestInit => ({
  ...init,
  headers: { ...(init.headers as Record<string, string>), Authorization: `Bearer ${token}` },
});

/** Cookie header built from a response's Set-Cookie headers. */
const cookiesFrom = (res: Response) =>
  res.headers
    .getSetCookie()
    .map((c) => c.split(";")[0]!)
    .join("; ");

const b64url = (obj: unknown) => btoa(JSON.stringify(obj)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

/** Mock Google's token endpoint to sign in as `sub`; other fetches pass through. */
function mockGoogle(sub: string, email = `${sub}@example.com`) {
  const original = globalThis.fetch;
  const calls: URLSearchParams[] = [];
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const url = input instanceof Request ? input.url : String(input);
    if (url !== GOOGLE_TOKEN_URL) return original(input, init);
    calls.push(new URLSearchParams(String(init?.body)));
    const idToken = [
      b64url({ alg: "RS256" }),
      b64url({ iss: "https://accounts.google.com", aud: env.GOOGLE_CLIENT_ID, sub, email, name: "Test User", exp: Math.floor(Date.now() / 1000) + 3600 }),
      "sig",
    ].join(".");
    return Response.json({ access_token: "google-access", id_token: idToken, token_type: "Bearer" });
  });
  return calls;
}

beforeEach(() => resetDb(env.DB));
afterEach(() => vi.restoreAllMocks());

describe("landing page", () => {
  it("explains how to connect", async () => {
    const res = await call("/");
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).toContain("https://cloud.test/mcp");
    expect(html).not.toMatch(/<script|<link|https?:\/\/fonts/);
  });
});

describe("/app/login", () => {
  const bad = [
    "",
    "?state=abcdefgh12345678",
    "?redirect_uri=https%3A%2F%2Fevil.example&state=abcdefgh12345678",
    "?redirect_uri=openscribe%3A%2F%2Fauth.evil.example&state=abcdefgh12345678",
    "?redirect_uri=openscribe%3A%2F%2Fauth%2Fx&state=abcdefgh12345678",
    "?redirect_uri=OPENSCRIBE%3A%2F%2Fauth&state=abcdefgh12345678",
    "?redirect_uri=openscribe%3A%2F%2Fauth&redirect_uri=https%3A%2F%2Fevil.example&state=abcdefgh12345678",
    "?redirect_uri=openscribe%3A%2F%2Fauth",
    "?redirect_uri=openscribe%3A%2F%2Fauth&state=short",
    "?redirect_uri=openscribe%3A%2F%2Fauth&state=has%20spaces%20in%20it",
  ];
  it.each(bad)("rejects %s without redirecting", async (query) => {
    const res = await call(`/app/login${query}`);
    expect(res.status).toBe(400);
    expect(res.headers.get("Location")).toBeNull();
    expect(res.headers.get("Set-Cookie")).toBeNull();
  });

  it("signs in with Google and redirects to openscribe://auth with a working token", async () => {
    const appState = randomToken(16);
    const start = await call(`/app/login?redirect_uri=openscribe%3A%2F%2Fauth&state=${appState}`);
    expect(start.status).toBe(302);
    const google = new URL(start.headers.get("Location")!);
    expect(google.origin).toBe("https://accounts.google.com");
    expect(google.searchParams.get("redirect_uri")).toBe("https://cloud.test/callback");
    expect(google.searchParams.get("code_challenge_method")).toBe("S256");
    const googleState = google.searchParams.get("state")!;
    expect(googleState).not.toContain(appState); // the app's state never leaves our server
    const cookie = cookiesFrom(start);
    expect(start.headers.get("Set-Cookie")).toMatch(/^__Host-[^;]+;.*Secure;.*HttpOnly;.*SameSite=Lax/);

    const tokenCalls = mockGoogle("google-sub-1");

    // Without the browser-binding cookie (CSRF / login injection): refused.
    const forged = await call(`/callback?code=c&state=${encodeURIComponent(googleState)}`);
    expect(forged.status).toBe(400);
    expect(forged.headers.get("Location")).toBeNull();

    const done = await call(`/callback?code=c&state=${encodeURIComponent(googleState)}`, { headers: { Cookie: cookie } });
    expect(done.status).toBe(302);
    const redirect = new URL(done.headers.get("Location")!);
    expect(`${redirect.protocol}//${redirect.host}`).toBe("openscribe://auth");
    expect(redirect.searchParams.get("state")).toBe(appState);
    const token = redirect.searchParams.get("token")!;
    expect(token).toMatch(/^osk_/);
    expect(tokenCalls[0]!.get("code_verifier")).toBeTruthy();

    // Single use.
    const replay = await call(`/callback?code=c&state=${encodeURIComponent(googleState)}`, { headers: { Cookie: cookie } });
    expect(replay.status).toBe(400);

    // Stored hashed, never in plaintext.
    const stored = await env.DB.prepare("SELECT token_hash FROM app_tokens").all<{ token_hash: string }>();
    expect(stored.results).toHaveLength(1);
    expect(stored.results[0]!.token_hash).not.toContain(token);

    const me = await call("/api/v1/me", bearer(token));
    expect(me.status).toBe(200);
    expect(await me.json()).toEqual({ email: "google-sub-1@example.com", name: "Test User", documentCount: 0, lastSyncAt: null, attachmentCount: 0, attachmentBytes: 0 });
  });

  it("passes a Google error back to the app with its state", async () => {
    const appState = randomToken(16);
    const start = await call(`/app/login?redirect_uri=openscribe%3A%2F%2Fauth&state=${appState}`);
    const googleState = new URL(start.headers.get("Location")!).searchParams.get("state")!;
    const res = await call(`/callback?error=access_denied&state=${encodeURIComponent(googleState)}`, { headers: { Cookie: cookiesFrom(start) } });
    expect(res.headers.get("Location")).toBe(`openscribe://auth?error=access_denied&state=${appState}`);
  });
});

describe("sync API auth", () => {
  it("rejects missing, malformed, unknown and revoked tokens", async () => {
    expect((await call("/api/v1/me")).status).toBe(401);
    expect((await call("/api/v1/me", bearer("not-a-token"))).status).toBe(401);
    expect((await call("/api/v1/me", bearer(`osk_${randomToken(32)}`))).status).toBe(401);

    const token = await seedUserWithToken(env.DB, "u1");
    expect((await call("/api/v1/me", bearer(token))).status).toBe(200);
    const logout = await call("/api/v1/logout", bearer(token, { method: "POST" }));
    expect(logout.status).toBe(200);
    const after = await call("/api/v1/me", bearer(token));
    expect(after.status).toBe(401);
    expect(after.headers.get("WWW-Authenticate")).toContain("Bearer");
  });
});

describe("sync API documents", () => {
  const post = (token: string, body: string) =>
    call("/api/v1/documents/batch", bearer(token, { method: "POST", body, headers: { "Content-Type": "application/json" } }));

  it("upserts a batch, reports counts, and updates /me", async () => {
    const token = await seedUserWithToken(env.DB, "u1");
    const docs = [makeDoc({ id: "1" }), makeDoc({ id: "2", kind: "meeting" })];
    const res = await post(token, JSON.stringify({ documents: docs }));
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ accepted: 2, skipped: 0, errors: [] });
    expect(await (await post(token, JSON.stringify({ documents: docs }))).json()).toMatchObject({ accepted: 0, skipped: 2 });

    const del = await call("/api/v1/documents/2", bearer(token, { method: "DELETE" }));
    expect(del.status).toBe(200);
    const me = (await (await call("/api/v1/me", bearer(token))).json()) as { documentCount: number; lastSyncAt: string };
    expect(me.documentCount).toBe(1);
    expect(Date.parse(me.lastSyncAt)).toBeGreaterThan(0);
  });

  it("enforces the 200-document and 5 MB limits", async () => {
    const token = await seedUserWithToken(env.DB, "u1");
    const tooMany = Array.from({ length: 201 }, (_, i) => makeDoc({ id: String(i) }));
    expect((await post(token, JSON.stringify({ documents: tooMany }))).status).toBe(413);
    const huge = JSON.stringify({ documents: [makeDoc({ body: "x".repeat(5 * 1024 * 1024) })] });
    expect((await post(token, huge)).status).toBe(413);
    expect((await post(token, "{not json")).status).toBe(400);
    expect((await post(token, JSON.stringify({ docs: [] }))).status).toBe(400);
  });
});

describe("remote MCP over OAuth", () => {
  /** Register a client and walk the real browser flow (consent → Google → callback → token). */
  async function connect(sub: string) {
    const redirectUri = "https://client.example/callback";
    const reg = await call("/register", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ client_name: "Test Client", redirect_uris: [redirectUri], token_endpoint_auth_method: "none" }),
    });
    expect(reg.status).toBe(201);
    const { client_id } = (await reg.json()) as { client_id: string };

    const verifier = randomToken(48);
    const authorize = new URL(`${BASE}/authorize`);
    for (const [k, v] of Object.entries({
      response_type: "code",
      client_id,
      redirect_uri: redirectUri,
      state: "client-state",
      code_challenge: await pkceChallenge(verifier),
      code_challenge_method: "S256",
      scope: "openscribe:read",
      resource: `${BASE}/mcp`,
    }))
      authorize.searchParams.set(k, v);

    const consent = await call(authorize.pathname + authorize.search);
    expect(consent.status).toBe(200);
    expect(consent.headers.get("X-Frame-Options") ?? consent.headers.get("Content-Security-Policy")).toBeTruthy();
    const html = await consent.text();
    expect(html).toContain("Test Client");
    const handle = /name="handle" value="([^"]+)"/.exec(html)![1]!;

    const approve = await call("/authorize", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded", Cookie: cookiesFrom(consent) },
      body: new URLSearchParams({ handle, decision: "approve" }),
    });
    expect(approve.status).toBe(302);
    const google = new URL(approve.headers.get("Location")!);
    expect(google.origin).toBe("https://accounts.google.com");

    mockGoogle(sub);
    const cb = await call(`/callback?code=g&state=${encodeURIComponent(google.searchParams.get("state")!)}`, {
      headers: { Cookie: cookiesFrom(approve) },
    });
    expect(cb.status).toBe(302);
    const back = new URL(cb.headers.get("Location")!);
    expect(back.origin + back.pathname).toBe(redirectUri);
    expect(back.searchParams.get("state")).toBe("client-state");

    const tokenRes = await call("/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "authorization_code",
        code: back.searchParams.get("code")!,
        redirect_uri: redirectUri,
        client_id,
        code_verifier: verifier,
        resource: `${BASE}/mcp`,
      }),
    });
    expect(tokenRes.status).toBe(200);
    const { access_token } = (await tokenRes.json()) as { access_token: string };
    return access_token;
  }

  const rpc = (token: string, body: unknown) =>
    call("/mcp", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
        Accept: "application/json, text/event-stream",
        "MCP-Protocol-Version": "2025-06-18",
      },
      body: JSON.stringify(body),
    });

  async function rpcJson(token: string, body: unknown): Promise<any> {
    const res = await rpc(token, body);
    expect(res.status).toBe(200);
    const text = await res.text();
    if (res.headers.get("Content-Type")?.includes("text/event-stream")) {
      const data = text.split("\n").filter((l) => l.startsWith("data:")).map((l) => l.slice(5).trim());
      return JSON.parse(data.at(-1)!);
    }
    return JSON.parse(text);
  }

  it("rejects unauthenticated requests with a discoverable challenge", async () => {
    const res = await call("/mcp", { method: "POST", body: "{}" });
    expect(res.status).toBe(401);
    expect(res.headers.get("WWW-Authenticate")).toContain("resource_metadata");
    const meta = await call("/.well-known/oauth-protected-resource/mcp");
    expect(meta.status).toBe(200);
    expect(await meta.json()).toMatchObject({ resource: `${BASE}/mcp`, authorization_servers: [BASE] });
    const as = await call("/.well-known/oauth-authorization-server");
    expect(await as.json()).toMatchObject({ registration_endpoint: `${BASE}/register` });
  });

  it("serves the read-only tools for the signed-in user only, and account deletion revokes access", async () => {
    const appToken = await seedUserWithToken(env.DB, "sub-a");
    await call("/api/v1/documents/batch", bearer(appToken, {
      method: "POST",
      body: JSON.stringify({ documents: [makeDoc({ id: "mine", title: "Pelican migration notes" })] }),
    }));
    await seedUserWithToken(env.DB, "sub-b");
    const tokenA = await connect("sub-a");
    const tokenB = await connect("sub-b");

    const init = await rpcJson(tokenA, {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" } },
    });
    expect(init.result.serverInfo.name).toBe("openscribe");

    const list = await rpcJson(tokenA, { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });
    const tools = list.result.tools as { name: string; annotations: { readOnlyHint: boolean } }[];
    expect(tools.map((t) => t.name).sort()).toEqual(["fetch", "get_attachment", "get_meeting", "list_action_items", "list_recent", "search"]);
    expect(tools.every((t) => t.annotations.readOnlyHint)).toBe(true);

    const searchCall = { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "search", arguments: { query: "pelican" } } };
    const a = await rpcJson(tokenA, searchCall);
    expect(a.result.structuredContent.results.map((r: { id: string }) => r.id)).toEqual(["mine"]);
    const b = await rpcJson(tokenB, searchCall);
    expect(b.result.structuredContent.results).toEqual([]);

    // Attachments: image content and resource links pass through the SDK unchanged; other users can't see them.
    const png = Uint8Array.from(atob("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="), (ch) => ch.charCodeAt(0));
    const audio = new Uint8Array(2048).fill(7);
    for (const [id, bytes, type, kind] of [["shot", png, "image/png", "screenshot"], ["rec", audio, "audio/mp4", "recording"]] as const) {
      const digest = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))].map((x) => x.toString(16).padStart(2, "0")).join("");
      const put = await call(`/api/v1/attachments/mine/${id}`, bearer(appToken, {
        method: "PUT",
        body: bytes,
        headers: { "Content-Type": type, "Content-Length": String(bytes.byteLength), "X-OpenScribe-Kind": kind, "X-OpenScribe-Sha256": digest },
      }));
      expect(put.status).toBe(201);
    }
    const attCall = (name: string, args: unknown) => ({ jsonrpc: "2.0", id: 4, method: "tools/call", params: { name, arguments: args } });
    const fetched = await rpcJson(tokenA, attCall("fetch", { id: "mine" }));
    expect(fetched.result.structuredContent.attachments.map((x: { id: string }) => x.id).sort()).toEqual(["rec", "shot"]);
    const image = await rpcJson(tokenA, attCall("get_attachment", { documentId: "mine", id: "shot" }));
    expect(image.result.content[0]).toMatchObject({ type: "image", mimeType: "image/png", data: btoa(String.fromCharCode(...png)) });
    const link = await rpcJson(tokenA, attCall("get_attachment", { documentId: "mine", id: "rec" }));
    expect(link.result.content[1]).toMatchObject({ type: "resource_link", mimeType: "audio/mp4", size: 2048 });
    const media = await call(new URL(link.result.content[1].uri).pathname);
    expect(media.status).toBe(200);
    expect((await media.arrayBuffer()).byteLength).toBe(2048);
    const denied = await rpcJson(tokenB, attCall("get_attachment", { documentId: "mine", id: "shot" }));
    expect(denied.result.isError).toBe(true);

    // DELETE /account wipes documents and tokens and revokes OAuth grants.
    const del = await call("/api/v1/account", bearer(appToken, { method: "DELETE" }));
    expect(del.status).toBe(200);
    expect((await call("/api/v1/me", bearer(appToken))).status).toBe(401);
    expect((await rpc(tokenA, searchCall)).status).toBe(401);
    expect((await env.MEDIA.list({ prefix: "u/sub-a/" })).objects).toEqual([]);
    const counts = await env.DB.prepare(
      "SELECT (SELECT COUNT(*) FROM attachments WHERE user_id = 'sub-a') AS a, (SELECT COUNT(*) FROM documents WHERE user_id = 'sub-a') AS d, (SELECT COUNT(*) FROM app_tokens WHERE user_id = 'sub-a') AS t, (SELECT COUNT(*) FROM users WHERE id = 'sub-a') AS u",
    ).first();
    expect(counts).toEqual({ a: 0, d: 0, t: 0, u: 0 });
    // User B is unaffected.
    expect((await rpc(tokenB, searchCall)).status).toBe(200);
  });
});
