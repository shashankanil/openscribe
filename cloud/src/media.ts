/**
 * Signed, expiring media URLs: `GET /media/<token>` serves one attachment without an auth header.
 * Token = base64url(JSON {u, d, a, exp}) "." base64url(HMAC-SHA256(payload)), keyed by a key derived
 * from COOKIE_ENCRYPTION_KEY so it can't be confused with any cookie signature.
 */
import { attachmentFilename, type AttachmentRow } from "./attachments";
import { base64url, base64urlDecode, hmacSha256, timingSafeEqual } from "./crypto";

export const MEDIA_URL_TTL_SECONDS = 3600;
const KEY_LABEL = "openscribe-media-v1";

export interface MediaTokenPayload {
  u: string;
  d: string;
  a: string;
  /** Expiry, epoch seconds. */
  exp: number;
}

let derived: { secret: string; key: Promise<ArrayBuffer> } | undefined;
function mediaKey(secret: string): Promise<ArrayBuffer> {
  if (derived?.secret !== secret) derived = { secret, key: hmacSha256(secret, KEY_LABEL) };
  return derived.key;
}

const encoder = new TextEncoder();
const sign = async (secret: string, payload: string) => base64url(new Uint8Array(await hmacSha256(await mediaKey(secret), payload)));

export async function signMediaToken(secret: string, payload: MediaTokenPayload): Promise<string> {
  const body = base64url(encoder.encode(JSON.stringify(payload)));
  return `${body}.${await sign(secret, body)}`;
}

/** The payload if the signature is valid and unexpired, else null. */
export async function verifyMediaToken(secret: string, token: string, now = Date.now()): Promise<MediaTokenPayload | null> {
  const [body, signature, extra] = token.split(".");
  if (!body || !signature || extra !== undefined || body.length > 2048) return null;
  if (!timingSafeEqual(signature, await sign(secret, body))) return null;
  const bytes = base64urlDecode(body);
  if (!bytes) return null;
  try {
    const p = JSON.parse(new TextDecoder().decode(bytes)) as Partial<MediaTokenPayload>;
    if (typeof p.u !== "string" || typeof p.d !== "string" || typeof p.a !== "string" || typeof p.exp !== "number") return null;
    return p.exp * 1000 > now ? (p as MediaTokenPayload) : null;
  } catch {
    return null;
  }
}

/** Per-user access to attachment bytes and signed URLs, handed to the MCP tools. */
export interface MediaAccess {
  bucket: R2Bucket;
  url(documentId: string, attachmentId: string): Promise<string>;
}

export function mediaAccess(env: Env, userId: string, now: () => number = Date.now): MediaAccess {
  const origin = env.PUBLIC_URL.replace(/\/+$/, "");
  return {
    bucket: env.MEDIA,
    async url(documentId, attachmentId) {
      const exp = Math.floor(now() / 1000) + MEDIA_URL_TTL_SECONDS;
      return `${origin}/media/${await signMediaToken(env.COOKIE_ENCRYPTION_KEY, { u: userId, d: documentId, a: attachmentId, exp })}`;
    },
  };
}

/** Parse a single `bytes=` range. null → serve the whole object (absent, malformed or multi-range). */
export function parseRange(header: string | null, size: number): { offset: number; length: number } | "unsatisfiable" | null {
  const m = header ? /^bytes=(\d*)-(\d*)$/.exec(header.trim()) : null;
  if (!m || (!m[1] && !m[2])) return null;
  let start: number;
  let end = size - 1;
  if (!m[1]) {
    const suffix = Number(m[2]);
    if (suffix === 0) return "unsatisfiable";
    start = Math.max(0, size - suffix);
  } else {
    start = Number(m[1]);
    if (m[2]) {
      if (Number(m[2]) < start) return null;
      end = Math.min(Number(m[2]), size - 1);
    }
  }
  if (start >= size) return "unsatisfiable";
  return { offset: start, length: end - start + 1 };
}

const mediaError = (status: number, error: string) => Response.json({ error }, { status, headers: { "Cache-Control": "no-store" } });

export async function serveMedia(env: Env, request: Request, token: string): Promise<Response> {
  const payload = await verifyMediaToken(env.COOKIE_ENCRYPTION_KEY, token);
  if (!payload) return mediaError(403, "forbidden");
  const row = await env.DB.prepare(
    `SELECT a.id, a.content_type, a.bytes, a.r2_key, COALESCE(d.title, '') AS title FROM attachments a
     LEFT JOIN documents d ON d.user_id = a.user_id AND d.id = a.document_id
     WHERE a.user_id = ?1 AND a.document_id = ?2 AND a.id = ?3`,
  )
    .bind(payload.u, payload.d, payload.a)
    .first<Pick<AttachmentRow, "id" | "content_type" | "bytes" | "r2_key"> & { title: string }>();
  if (!row) return mediaError(404, "not_found");

  const range = parseRange(request.headers.get("Range"), row.bytes);
  const headers = new Headers({
    "Accept-Ranges": "bytes",
    "Content-Type": row.content_type,
    "Content-Disposition": `inline; filename="${attachmentFilename(row.title, row)}"`,
    "Cache-Control": "private, max-age=3600",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
  });
  if (range === "unsatisfiable") {
    headers.set("Content-Range", `bytes */${row.bytes}`);
    return new Response(null, { status: 416, headers });
  }
  const object = await env.MEDIA.get(row.r2_key, range ? { range } : undefined);
  if (!object) return mediaError(404, "not_found");
  headers.set("ETag", object.httpEtag);
  if (range) {
    headers.set("Content-Range", `bytes ${range.offset}-${range.offset + range.length - 1}/${object.size}`);
    headers.set("Content-Length", String(range.length));
    return new Response(object.body, { status: 206, headers });
  }
  headers.set("Content-Length", String(object.size));
  return new Response(object.body, { status: 200, headers });
}
