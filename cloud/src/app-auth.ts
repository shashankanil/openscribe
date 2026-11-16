/**
 * Desktop-app sign-in (`/app/login` → Google → `openscribe://auth?token=…&state=…`) and
 * the opaque app tokens that authorize `/api/v1`.
 */
import { randomToken, sha256Hex, timingSafeEqual } from "./crypto";

export const APP_REDIRECT_URI = "openscribe://auth";
/** Prefix on the Google `state` that routes `/callback` to the app flow. */
export const APP_STATE_PREFIX = "app.";
export const APP_LOGIN_COOKIE = "__Host-openscribe-app-login";
const APP_LOGIN_TTL_SECONDS = 600;
const APP_TOKEN_PREFIX = "osk_";
/** The app's own CSRF state: opaque, URL-safe, bounded. */
const APP_STATE_PATTERN = /^[A-Za-z0-9._~-]{8,512}$/;

export interface AppLoginParams {
  appState: string;
}

/** Strictly validate `/app/login` query parameters. Returns an error message, or the params. */
export function validateAppLoginParams(url: URL): { error: string } | AppLoginParams {
  const redirectUris = url.searchParams.getAll("redirect_uri");
  const states = url.searchParams.getAll("state");
  if (redirectUris.length !== 1 || redirectUris[0] !== APP_REDIRECT_URI) {
    return { error: `redirect_uri must be exactly ${APP_REDIRECT_URI}` };
  }
  if (states.length !== 1 || !APP_STATE_PATTERN.test(states[0]!)) {
    return { error: "state is required (8-512 URL-safe characters)" };
  }
  return { appState: states[0]! };
}

interface PendingAppLogin {
  appState: string;
  verifier: string;
}

const kvKey = async (nonce: string) => `app-login:${await sha256Hex(nonce)}`;

/**
 * Start an app login: store the app's state and a PKCE verifier server-side under a random
 * nonce, bind the nonce to this browser with a `__Host-` cookie, and return the Google state.
 */
export async function beginAppLogin(kv: KVNamespace, appState: string): Promise<{ googleState: string; verifier: string; setCookie: string }> {
  const nonce = randomToken(32);
  const verifier = randomToken(48);
  const pending: PendingAppLogin = { appState, verifier };
  await kv.put(await kvKey(nonce), JSON.stringify(pending), { expirationTtl: APP_LOGIN_TTL_SECONDS });
  return {
    googleState: APP_STATE_PREFIX + nonce,
    verifier,
    setCookie: `${APP_LOGIN_COOKIE}=${nonce}; Max-Age=${APP_LOGIN_TTL_SECONDS}; Path=/; Secure; HttpOnly; SameSite=Lax`,
  };
}

export const clearAppLoginCookie = `${APP_LOGIN_COOKIE}=; Max-Age=0; Path=/; Secure; HttpOnly; SameSite=Lax`;

function readCookie(request: Request, name: string): string | null {
  const header = request.headers.get("Cookie");
  if (!header) return null;
  for (const part of header.split(";")) {
    const [k, ...v] = part.trim().split("=");
    if (k === name) return v.join("=");
  }
  return null;
}

/**
 * Finish an app login at `/callback`: the Google state must carry a nonce that matches this
 * browser's cookie and an unexpired, unused KV record. Single use.
 */
export async function finishAppLogin(kv: KVNamespace, request: Request, googleState: string): Promise<PendingAppLogin | null> {
  if (!googleState.startsWith(APP_STATE_PREFIX)) return null;
  const nonce = googleState.slice(APP_STATE_PREFIX.length);
  const cookie = readCookie(request, APP_LOGIN_COOKIE);
  if (!nonce || !cookie || !timingSafeEqual(nonce, cookie)) return null;
  const key = await kvKey(nonce);
  const raw = await kv.get(key);
  if (!raw) return null;
  await kv.delete(key);
  const pending = JSON.parse(raw) as PendingAppLogin;
  return APP_STATE_PATTERN.test(pending.appState) ? pending : null;
}

export function appRedirect(params: Record<string, string>): string {
  return `${APP_REDIRECT_URI}?${new URLSearchParams(params).toString()}`;
}

// ---------------------------------------------------------------------------------------------
// App tokens

export async function issueAppToken(db: D1Database, userId: string, now = Date.now()): Promise<string> {
  const token = APP_TOKEN_PREFIX + randomToken(32);
  await db
    .prepare("INSERT INTO app_tokens (token_hash, user_id, created_at) VALUES (?1, ?2, ?3)")
    .bind(await sha256Hex(token), userId, now)
    .run();
  return token;
}

export interface AppPrincipal {
  userId: string;
  tokenHash: string;
}

/** Resolve `Authorization: Bearer <app token>` to a user, or null if missing/unknown/revoked. */
export async function authenticateAppToken(db: D1Database, request: Request): Promise<AppPrincipal | null> {
  const header = request.headers.get("Authorization") ?? "";
  const match = /^Bearer\s+(\S+)$/i.exec(header);
  if (!match || !match[1]!.startsWith(APP_TOKEN_PREFIX)) return null;
  const tokenHash = await sha256Hex(match[1]!);
  const row = await db
    .prepare(
      `SELECT t.user_id AS user_id, t.last_used_at AS last_used_at FROM app_tokens t JOIN users u ON u.id = t.user_id
       WHERE t.token_hash = ?1 AND t.revoked_at IS NULL`,
    )
    .bind(tokenHash)
    .first<{ user_id: string; last_used_at: number | null }>();
  if (!row) return null;
  const now = Date.now();
  if (row.last_used_at === null || now - row.last_used_at > 3_600_000) {
    await db.prepare("UPDATE app_tokens SET last_used_at = ?1 WHERE token_hash = ?2").bind(now, tokenHash).run();
  }
  return { userId: row.user_id, tokenHash };
}

export async function revokeAppToken(db: D1Database, tokenHash: string, now = Date.now()): Promise<void> {
  await db.prepare("UPDATE app_tokens SET revoked_at = ?1 WHERE token_hash = ?2 AND revoked_at IS NULL").bind(now, tokenHash).run();
}
