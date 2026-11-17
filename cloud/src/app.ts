/**
 * Everything that isn't the OAuth-protected `/mcp` route: the landing page, the OAuth
 * consent + Google sign-in for MCP clients, the desktop app's `/app/login`, and `/api/v1`.
 */
import { AuthorizationError, authorizationErrorRedirect, CimdFetchError, type AuthRequest, type OAuthHelpers } from "@cloudflare/workers-oauth-provider";
import { Hono, type Context } from "hono";
import {
  APP_STATE_PREFIX,
  appRedirect,
  authenticateAppToken,
  beginAppLogin,
  clearAppLoginCookie,
  finishAppLogin,
  issueAppToken,
  revokeAppToken,
  validateAppLoginParams,
  type AppPrincipal,
} from "./app-auth";
import {
  deleteAttachment,
  getAttachmentRow,
  isValidId,
  listAttachmentRows,
  MAX_ATTACHMENT_BYTES,
  MAX_CAPTION_CHARS,
  MEDIA_TYPES,
  purgeTombstonedAttachments,
  purgeUserMedia,
  r2Key,
  updateAttachmentMetadata,
  upsertAttachmentRow,
  usedBytes,
} from "./attachments";
import { randomToken } from "./crypto";
import { deleteDocument, MAX_BATCH_BYTES, MAX_DOCUMENTS_PER_BATCH, upsertDocuments } from "./documents";
import { exchangeGoogleCode, googleAuthorizeUrl, GoogleAuthError, upsertUser } from "./google";
import { consentPage, errorPage, HTML_HEADERS, landingPage, privacyPage, termsPage } from "./html";
import { serveMedia } from "./media";

export type Bindings = Env & { OAUTH_PROVIDER: OAuthHelpers };
type Variables = { principal: AppPrincipal };
type AppContext = Context<{ Bindings: Bindings; Variables: Variables }>;

/** Scopes this server grants. `openscribe:read` is the only resource scope. */
export const READ_SCOPE = "openscribe:read";
/** Refresh tokens are issued regardless of `offline_access`; it is listed so clients that ask for it aren't refused. */
export const SCOPES_SUPPORTED = [READ_SCOPE, "offline_access"];

const publicUrl = (env: Env) => env.PUBLIC_URL.replace(/\/+$/, "");

function htmlError(message: string, status: 400 | 403 | 500 = 400): Response {
  return new Response(errorPage(message), { status, headers: { ...HTML_HEADERS, "Cache-Control": "no-store" } });
}

function jsonError(status: number, error: string, description?: string): Response {
  const headers: Record<string, string> = { "Cache-Control": "no-store" };
  if (status === 401) headers["WWW-Authenticate"] = 'Bearer realm="openscribe"';
  return Response.json({ error, ...(description ? { error_description: description } : {}) }, { status, headers });
}

function requireSecrets(env: Env): Response | null {
  if (!env.GOOGLE_CLIENT_ID || !env.GOOGLE_CLIENT_SECRET || !env.COOKIE_ENCRYPTION_KEY || env.COOKIE_ENCRYPTION_KEY.length < 32) {
    console.error("Missing GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET / COOKIE_ENCRYPTION_KEY (>= 32 chars)");
    return htmlError("This server isn't configured for sign-in yet.", 500);
  }
  return null;
}

/** Render or redirect an OAuth error per the library's guidance (consent-page.md). */
function oauthErrorResponse(error: unknown): Response {
  if (error instanceof AuthorizationError && error.redirectTo) return Response.redirect(error.redirectTo, 302);
  if (error instanceof AuthorizationError) return htmlError(error.description);
  if (error instanceof CimdFetchError) return htmlError("This app could not be verified.");
  if (error instanceof GoogleAuthError) return htmlError(error.message, 403);
  throw error;
}

async function redirectToGoogle(env: Env, request: AuthRequest, headers: Headers, oauth: OAuthHelpers): Promise<Response> {
  const verifier = randomToken(48);
  const upstream = await oauth.beginUpstream(request, { data: { verifier }, headers });
  upstream.headers.set("Location", await googleAuthorizeUrl(env, upstream.state, verifier));
  upstream.headers.set("Cache-Control", "no-store");
  return new Response(null, { status: 302, headers: upstream.headers });
}

const rememberConsent = (env: Env) => ({ secret: env.COOKIE_ENCRYPTION_KEY });

/** Read a request body up to `limit` bytes; null if larger. */
async function readBodyLimited(request: Request, limit: number): Promise<string | null> {
  const declared = Number(request.headers.get("Content-Length") ?? "0");
  if (declared > limit) return null;
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > limit) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const all = new Uint8Array(size);
  let offset = 0;
  for (const c of chunks) {
    all.set(c, offset);
    offset += c.byteLength;
  }
  return new TextDecoder().decode(all);
}

export const app = new Hono<{ Bindings: Bindings; Variables: Variables }>();

// ---------------------------------------------------------------------------------------------
// Landing page

app.get("/", (c) =>
  c.html(landingPage(publicUrl(c.env), c.env.APP_DOWNLOAD_URL), 200, { ...HTML_HEADERS, "Cache-Control": "public, max-age=300" }),
);

app.get("/privacy", (c) => c.html(privacyPage(), 200, { ...HTML_HEADERS, "Cache-Control": "public, max-age=3600" }));
app.get("/terms", (c) => c.html(termsPage(), 200, { ...HTML_HEADERS, "Cache-Control": "public, max-age=3600" }));

app.get("/healthz", (c) => c.json({ ok: true }));

/** Signed attachment URLs (see media.ts). Authorized by the token itself, not a header. */
app.get("/media/:token", (c) => serveMedia(c.env, c.req.raw, c.req.param("token")));

// ---------------------------------------------------------------------------------------------
// OAuth for MCP clients: consent (per client), then Google, then completeAuthorization.

app.get("/authorize", async (c) => {
  const misconfigured = requireSecrets(c.env);
  if (misconfigured) return misconfigured;
  const oauth = c.env.OAUTH_PROVIDER;
  try {
    const request = await oauth.parseAuthRequest(c.req.raw);
    const details = await oauth.describeConsent(request);
    if (await oauth.isConsentRemembered(c.req.raw, request, rememberConsent(c.env))) {
      return redirectToGoogle(c.env, request, new Headers(), oauth);
    }
    const consent = await oauth.beginConsent(request);
    for (const [k, v] of Object.entries(HTML_HEADERS)) if (!consent.headers.has(k)) consent.headers.set(k, v);
    consent.headers.set("Content-Type", HTML_HEADERS["Content-Type"]);
    return new Response(consentPage(details, consent.handle), { headers: consent.headers });
  } catch (error) {
    return oauthErrorResponse(error);
  }
});

app.post("/authorize", async (c) => {
  const misconfigured = requireSecrets(c.env);
  if (misconfigured) return misconfigured;
  const oauth = c.env.OAUTH_PROVIDER;
  try {
    const form = await c.req.raw.formData();
    const handle = String(form.get("handle") ?? "");
    if (form.get("decision") !== "approve") {
      const denied = await oauth.denyConsent(c.req.raw, handle);
      return new Response(null, { status: 302, headers: denied.headers });
    }
    const approved = await oauth.approveConsent(c.req.raw, handle, { scope: [READ_SCOPE], remember: rememberConsent(c.env) });
    return redirectToGoogle(c.env, approved.request, approved.headers, oauth);
  } catch (error) {
    return oauthErrorResponse(error);
  }
});

/** Google redirects here for both flows. App logins carry a state prefixed with `app.`. */
app.get("/callback", async (c) => {
  const misconfigured = requireSecrets(c.env);
  if (misconfigured) return misconfigured;
  const state = c.req.query("state") ?? "";
  if (state.startsWith(APP_STATE_PREFIX)) return appCallback(c, state);

  const oauth = c.env.OAUTH_PROVIDER;
  try {
    const { request, data, headers } = await oauth.finishUpstream<{ verifier: string }>(c.req.raw);
    headers.set("Cache-Control", "no-store");
    const code = c.req.query("code");
    if (c.req.query("error") || !code) {
      headers.set("Location", authorizationErrorRedirect(request, "access_denied"));
      return new Response(null, { status: 302, headers });
    }
    const user = await exchangeGoogleCode(c.env, code, data.verifier);
    await upsertUser(c.env.DB, user);
    const { redirectTo } = await oauth.completeAuthorization({
      request,
      userId: user.sub,
      metadata: { label: user.email },
      scope: [READ_SCOPE],
      props: { userId: user.sub, email: user.email, name: user.name },
    });
    headers.set("Location", redirectTo);
    return new Response(null, { status: 302, headers });
  } catch (error) {
    return oauthErrorResponse(error);
  }
});

// ---------------------------------------------------------------------------------------------
// Desktop app login

app.get("/app/login", async (c) => {
  const params = validateAppLoginParams(new URL(c.req.url));
  if ("error" in params) return htmlError(params.error);
  const misconfigured = requireSecrets(c.env);
  if (misconfigured) return misconfigured;
  const { googleState, verifier, setCookie } = await beginAppLogin(c.env.OAUTH_KV, params.appState);
  return new Response(null, {
    status: 302,
    headers: { Location: await googleAuthorizeUrl(c.env, googleState, verifier), "Set-Cookie": setCookie, "Cache-Control": "no-store" },
  });
});

async function appCallback(c: AppContext, googleState: string): Promise<Response> {
  const pending = await finishAppLogin(c.env.OAUTH_KV, c.req.raw, googleState);
  if (!pending) {
    return htmlError("This sign-in link expired or was opened in a different browser. Start again from the OpenScribe app.");
  }
  const headers = new Headers({ "Cache-Control": "no-store", "Referrer-Policy": "no-referrer", "Set-Cookie": clearAppLoginCookie });
  const code = c.req.query("code");
  if (c.req.query("error") || !code) {
    headers.set("Location", appRedirect({ error: "access_denied", state: pending.appState }));
    return new Response(null, { status: 302, headers });
  }
  try {
    const user = await exchangeGoogleCode(c.env, code, pending.verifier);
    await upsertUser(c.env.DB, user);
    const token = await issueAppToken(c.env.DB, user.sub);
    headers.set("Location", appRedirect({ token, state: pending.appState }));
    return new Response(null, { status: 302, headers });
  } catch (error) {
    if (error instanceof GoogleAuthError) return htmlError(error.message, 403);
    throw error;
  }
}

// ---------------------------------------------------------------------------------------------
// Sync API (app token auth)

const api = new Hono<{ Bindings: Bindings; Variables: Variables }>();

api.use("*", async (c, next) => {
  const principal = await authenticateAppToken(c.env.DB, c.req.raw);
  if (!principal) return jsonError(401, "unauthorized", "Missing, invalid or revoked app token");
  c.set("principal", principal);
  await next();
  c.header("Cache-Control", "no-store");
});

api.get("/me", async (c) => {
  const { userId } = c.get("principal");
  const row = await c.env.DB.prepare(
    `SELECT u.email, u.name, u.last_sync_at,
            (SELECT COUNT(*) FROM documents d WHERE d.user_id = u.id AND d.deleted = 0) AS document_count,
            (SELECT COUNT(*) FROM attachments a WHERE a.user_id = u.id) AS attachment_count,
            (SELECT COALESCE(SUM(bytes), 0) FROM attachments a WHERE a.user_id = u.id) AS attachment_bytes
     FROM users u WHERE u.id = ?1`,
  )
    .bind(userId)
    .first<{ email: string; name: string; last_sync_at: number | null; document_count: number; attachment_count: number; attachment_bytes: number }>();
  if (!row) return jsonError(401, "unauthorized");
  return c.json({
    email: row.email,
    name: row.name,
    documentCount: row.document_count,
    lastSyncAt: row.last_sync_at === null ? null : new Date(row.last_sync_at).toISOString(),
    attachmentCount: row.attachment_count,
    attachmentBytes: row.attachment_bytes,
  });
});

api.post("/documents/batch", async (c) => {
  const text = await readBodyLimited(c.req.raw, MAX_BATCH_BYTES);
  if (text === null) return jsonError(413, "payload_too_large", `Body must be at most ${MAX_BATCH_BYTES} bytes`);
  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    return jsonError(400, "invalid_json");
  }
  const documents = (body as { documents?: unknown })?.documents;
  if (!Array.isArray(documents)) return jsonError(400, "invalid_request", "Expected { documents: [...] }");
  if (documents.length > MAX_DOCUMENTS_PER_BATCH) {
    return jsonError(413, "too_many_documents", `At most ${MAX_DOCUMENTS_PER_BATCH} documents per request`);
  }
  const { userId } = c.get("principal");
  const result = await upsertDocuments(c.env.DB, userId, documents);
  const tombstoned = documents.flatMap((d) => (d?.deleted === true && typeof d.id === "string" ? [d.id as string] : []));
  if (tombstoned.length > 0) await purgeTombstonedAttachments(c.env, userId, tombstoned);
  return c.json(result);
});

api.delete("/documents/:id", async (c) => {
  const id = c.req.param("id");
  if (!id || id.length > 200) return jsonError(400, "invalid_request");
  const { userId } = c.get("principal");
  await deleteDocument(c.env.DB, userId, id);
  await purgeTombstonedAttachments(c.env, userId, [id]);
  return c.json({ deleted: true });
});

api.post("/logout", async (c) => {
  await revokeAppToken(c.env.DB, c.get("principal").tokenHash);
  return c.json({ revoked: true });
});

api.delete("/account", async (c) => {
  const { userId } = c.get("principal");
  const oauth = c.env.OAUTH_PROVIDER;
  let cursor: string | undefined;
  do {
    const page = await oauth.listUserGrants(userId, cursor ? { cursor } : undefined);
    for (const grant of page.items) await oauth.revokeGrant(grant.id, userId);
    cursor = page.cursor;
  } while (cursor);
  await purgeUserMedia(c.env.MEDIA, userId);
  await c.env.DB.batch([
    c.env.DB.prepare("DELETE FROM attachments WHERE user_id = ?1").bind(userId),
    c.env.DB.prepare("DELETE FROM documents WHERE user_id = ?1").bind(userId),
    c.env.DB.prepare("DELETE FROM app_tokens WHERE user_id = ?1").bind(userId),
    c.env.DB.prepare("DELETE FROM users WHERE id = ?1").bind(userId),
  ]);
  return c.json({ deleted: true });
});

// ---------------------------------------------------------------------------------------------
// Attachments (screenshots, recordings) in R2

const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const DEFAULT_MEDIA_QUOTA_BYTES = 5 * 1024 ** 3;

api.put("/attachments/:documentId/:attachmentId", async (c) => {
  const { userId } = c.get("principal");
  const documentId = c.req.param("documentId");
  const id = c.req.param("attachmentId");
  if (!isValidId(documentId) || !isValidId(id)) return jsonError(400, "invalid_request", "Invalid document or attachment id");

  const contentType = (c.req.header("Content-Type") ?? "").split(";")[0]!.trim().toLowerCase();
  if (!(contentType in MEDIA_TYPES)) return jsonError(415, "unsupported_media_type", `Allowed: ${Object.keys(MEDIA_TYPES).join(", ")}`);
  const kind = c.req.header("X-OpenScribe-Kind");
  if (kind !== "screenshot" && kind !== "recording") return jsonError(400, "invalid_kind", "X-OpenScribe-Kind must be screenshot or recording");
  if (!contentType.startsWith(kind === "screenshot" ? "image/" : "audio/")) {
    return jsonError(400, "invalid_kind", `A ${kind} can't have Content-Type ${contentType}`);
  }
  const sha256 = (c.req.header("X-OpenScribe-Sha256") ?? "").toLowerCase();
  if (!SHA256_PATTERN.test(sha256)) return jsonError(400, "invalid_sha256", "X-OpenScribe-Sha256 must be 64 hex characters");

  const createdHeader = c.req.header("X-OpenScribe-Created-At");
  const createdAt = createdHeader === undefined ? undefined : Date.parse(createdHeader);
  if (Number.isNaN(createdAt)) return jsonError(400, "invalid_request", "X-OpenScribe-Created-At must be ISO-8601");
  const durationHeader = c.req.header("X-OpenScribe-Duration");
  const durationSeconds = durationHeader === undefined ? undefined : Number(durationHeader);
  if (durationSeconds !== undefined && (!durationHeader!.trim() || !Number.isFinite(durationSeconds) || durationSeconds < 0)) {
    return jsonError(400, "invalid_request", "X-OpenScribe-Duration must be seconds >= 0");
  }
  const captionHeader = c.req.header("X-OpenScribe-Caption");
  let caption: string | undefined;
  try {
    if (captionHeader !== undefined) caption = Array.from(decodeURIComponent(captionHeader)).slice(0, MAX_CAPTION_CHARS).join("");
  } catch {
    return jsonError(400, "invalid_request", "X-OpenScribe-Caption must be percent-encoded UTF-8");
  }

  const lengthHeader = c.req.header("Content-Length");
  if (!lengthHeader || !/^\d+$/.test(lengthHeader)) return jsonError(411, "length_required");
  const bytes = Number(lengthHeader);
  if (bytes > MAX_ATTACHMENT_BYTES) return jsonError(413, "too_large", `At most ${MAX_ATTACHMENT_BYTES} bytes`);
  if (bytes === 0 || !c.req.raw.body) return jsonError(400, "empty_body");

  const doc = await c.env.DB.prepare("SELECT 1 AS ok FROM documents WHERE user_id = ?1 AND id = ?2 AND deleted = 0").bind(userId, documentId).first();
  if (!doc) return jsonError(404, "document_not_found");

  const existing = await getAttachmentRow(c.env.DB, userId, documentId, id);
  if (existing?.sha256 === sha256) {
    await updateAttachmentMetadata(c.env.DB, userId, documentId, id, { kind, createdAt, durationSeconds, caption });
    return c.json({ id, documentId, kind, bytes: existing.bytes, sha256 }, 200);
  }

  const quota = Number(c.env.MEDIA_QUOTA_BYTES) || DEFAULT_MEDIA_QUOTA_BYTES;
  if ((await usedBytes(c.env.DB, userId, { documentId, id })) + bytes > quota) {
    return jsonError(413, "quota_exceeded", `Storage is limited to ${quota} bytes per account`);
  }

  try {
    // FixedLengthStream gives R2 the length up front and fails the put if the body is short or long.
    const body = c.req.raw.body.pipeThrough(new FixedLengthStream(bytes));
    await c.env.MEDIA.put(r2Key(userId, documentId, id), body, { httpMetadata: { contentType }, sha256 });
  } catch (error) {
    if (/sha-?256|checksum|digest/i.test(String(error))) return jsonError(400, "checksum_mismatch");
    throw error;
  }
  await upsertAttachmentRow(c.env.DB, userId, {
    documentId,
    id,
    kind,
    contentType,
    bytes,
    sha256,
    createdAt: createdAt ?? Date.now(),
    durationSeconds: durationSeconds ?? 0,
    caption: caption ?? "",
  });
  return c.json({ id, documentId, kind, bytes, sha256 }, 201);
});

api.get("/attachments", async (c) => {
  const rows = await listAttachmentRows(c.env.DB, c.get("principal").userId);
  return c.json({
    attachments: rows.map((r) => ({
      id: r.id,
      documentId: r.document_id,
      kind: r.kind,
      contentType: r.content_type,
      bytes: r.bytes,
      sha256: r.sha256,
      createdAt: new Date(r.created_at).toISOString(),
    })),
  });
});

api.delete("/attachments/:documentId/:attachmentId", async (c) => {
  const documentId = c.req.param("documentId");
  const id = c.req.param("attachmentId");
  if (!isValidId(documentId) || !isValidId(id)) return jsonError(400, "invalid_request");
  await deleteAttachment(c.env, c.get("principal").userId, documentId, id);
  return c.body(null, 204);
});

app.route("/api/v1", api);

app.notFound(() => jsonError(404, "not_found"));
app.onError((error) => {
  console.error("Unhandled error", error);
  return jsonError(500, "server_error");
});
