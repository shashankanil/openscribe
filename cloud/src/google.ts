/** Google as the upstream identity provider (OpenID Connect, authorization code + PKCE). */
import { pkceChallenge } from "./crypto";

export const GOOGLE_AUTHORIZE_URL = "https://accounts.google.com/o/oauth2/v2/auth";
export const GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token";
const GOOGLE_ISSUERS = new Set(["https://accounts.google.com", "accounts.google.com"]);

export interface GoogleIdentity {
  sub: string;
  email: string;
  name: string;
}

export class GoogleAuthError extends Error {}

/** The single redirect URI registered in Google Cloud console: `${PUBLIC_URL}/callback`. */
export function googleRedirectUri(env: Env): string {
  return `${env.PUBLIC_URL.replace(/\/+$/, "")}/callback`;
}

export async function googleAuthorizeUrl(env: Env, state: string, verifier: string): Promise<string> {
  const url = new URL(GOOGLE_AUTHORIZE_URL);
  url.searchParams.set("client_id", env.GOOGLE_CLIENT_ID);
  url.searchParams.set("redirect_uri", googleRedirectUri(env));
  url.searchParams.set("response_type", "code");
  url.searchParams.set("scope", "openid email profile");
  url.searchParams.set("state", state);
  url.searchParams.set("code_challenge", await pkceChallenge(verifier));
  url.searchParams.set("code_challenge_method", "S256");
  url.searchParams.set("prompt", "select_account");
  if (env.HOSTED_DOMAIN) url.searchParams.set("hd", env.HOSTED_DOMAIN);
  return url.href;
}

function decodeJwtPayload(jwt: string): Record<string, unknown> {
  const part = jwt.split(".")[1];
  if (!part) throw new GoogleAuthError("Malformed ID token");
  const b64 = part.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(part.length / 4) * 4, "=");
  const json = new TextDecoder().decode(Uint8Array.from(atob(b64), (c) => c.charCodeAt(0)));
  return JSON.parse(json) as Record<string, unknown>;
}

/**
 * Exchange an authorization code for the user's identity. The ID token comes straight from
 * Google's token endpoint over TLS, so per OIDC Core §3.1.3.7 we validate its claims
 * (iss, aud, exp) rather than its signature.
 */
export async function exchangeGoogleCode(env: Env, code: string, verifier: string, now = Date.now()): Promise<GoogleIdentity> {
  const res = await fetch(GOOGLE_TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded", Accept: "application/json" },
    body: new URLSearchParams({
      client_id: env.GOOGLE_CLIENT_ID,
      client_secret: env.GOOGLE_CLIENT_SECRET,
      code,
      code_verifier: verifier,
      grant_type: "authorization_code",
      redirect_uri: googleRedirectUri(env),
    }),
  });
  if (!res.ok) {
    console.error("Google token exchange failed", res.status, await res.text().catch(() => ""));
    throw new GoogleAuthError("Google sign-in failed. Please try again.");
  }
  const body = (await res.json()) as { id_token?: string };
  if (!body.id_token) throw new GoogleAuthError("Google did not return an ID token.");
  const claims = decodeJwtPayload(body.id_token);
  const aud = claims.aud;
  if (!GOOGLE_ISSUERS.has(String(claims.iss))) throw new GoogleAuthError("Unexpected ID token issuer.");
  if (Array.isArray(aud) ? !aud.includes(env.GOOGLE_CLIENT_ID) : aud !== env.GOOGLE_CLIENT_ID) {
    throw new GoogleAuthError("ID token was issued for a different client.");
  }
  if (typeof claims.exp !== "number" || claims.exp * 1000 < now - 60_000) throw new GoogleAuthError("ID token expired.");
  if (typeof claims.sub !== "string" || !claims.sub) throw new GoogleAuthError("ID token has no subject.");
  if (env.HOSTED_DOMAIN && claims.hd !== env.HOSTED_DOMAIN) {
    throw new GoogleAuthError(`Sign in with a ${env.HOSTED_DOMAIN} account.`);
  }
  return {
    sub: claims.sub,
    email: typeof claims.email === "string" ? claims.email : "",
    name: typeof claims.name === "string" ? claims.name : "",
  };
}

export async function upsertUser(db: D1Database, user: GoogleIdentity, now = Date.now()): Promise<void> {
  await db
    .prepare(
      `INSERT INTO users (id, email, name, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?4)
       ON CONFLICT (id) DO UPDATE SET email = excluded.email, name = excluded.name, updated_at = excluded.updated_at`,
    )
    .bind(user.sub, user.email, user.name, now)
    .run();
}
