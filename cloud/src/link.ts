/**
 * Phone Link (docs/PHONE-LINK.md, "OpenScribe Cloud: relay and images"): phone tokens the Mac
 * mints for its paired phones, auth that accepts either token type, and the short-lived
 * encrypted clipboard images in R2 at link/{userId}/{blobId}.
 */
import { authenticateAppToken } from "./app-auth";
import { randomToken, sha256Hex } from "./crypto";

const LINK_TOKEN_PREFIX = "oslp_";

/** The Mac's pairing slot id. */
export const DEVICE_ID_PATTERN = /^[A-Za-z0-9-]{1,100}$/;
export const MAX_DEVICE_NAME_CHARS = 100;

/** Room = hex(HKDF(pairing secret, …, 16 bytes)). */
export const ROOM_PATTERN = /^[0-9a-f]{32}$/;

/** 10 MiB of image plus the 12-byte nonce and 16-byte GCM tag. */
export const MAX_LINK_BLOB_BYTES = 10 * 1024 * 1024 + 28;
export const LINK_BLOB_TTL_MS = 2 * 86_400_000;
const BLOB_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export const isValidBlobId = (id: string | undefined): id is string => typeof id === "string" && BLOB_ID_PATTERN.test(id);

export const linkPrefix = (userId: string) => `link/${userId}/`;
export const linkBlobKey = (userId: string, blobId: string) => `${linkPrefix(userId)}${blobId}`;

export type LinkRole = "mac" | "phone";

export interface LinkPrincipal {
  userId: string;
  role: LinkRole;
}

// ---------------------------------------------------------------------------------------------
// Phone tokens

/** Revoke any live token for (user, device) and issue a new one. Returns the plaintext token. */
export async function issueLinkToken(db: D1Database, userId: string, deviceId: string, name: string, now = Date.now()): Promise<string> {
  const token = LINK_TOKEN_PREFIX + randomToken(32);
  await db.batch([
    db
      .prepare("UPDATE link_devices SET revoked_at = ?1 WHERE user_id = ?2 AND device_id = ?3 AND revoked_at IS NULL")
      .bind(now, userId, deviceId),
    db
      .prepare("INSERT INTO link_devices (token_hash, user_id, device_id, name, created_at) VALUES (?1, ?2, ?3, ?4, ?5)")
      .bind(await sha256Hex(token), userId, deviceId, name, now),
  ]);
  return token;
}

/** Revoke every live token for (user, device). Returns how many were revoked. */
export async function revokeLinkDevice(db: D1Database, userId: string, deviceId: string, now = Date.now()): Promise<number> {
  const res = await db
    .prepare("UPDATE link_devices SET revoked_at = ?1 WHERE user_id = ?2 AND device_id = ?3 AND revoked_at IS NULL")
    .bind(now, userId, deviceId)
    .run();
  return res.meta.changes;
}

/** Resolve `Authorization: Bearer oslp_…` to a user, or null if missing/unknown/revoked. */
export async function authenticateLinkToken(db: D1Database, request: Request): Promise<{ userId: string; deviceId: string } | null> {
  const header = request.headers.get("Authorization") ?? "";
  const match = /^Bearer\s+(\S+)$/i.exec(header);
  if (!match || !match[1]!.startsWith(LINK_TOKEN_PREFIX)) return null;
  const tokenHash = await sha256Hex(match[1]!);
  const row = await db
    .prepare(
      `SELECT d.user_id AS user_id, d.device_id AS device_id, d.last_used_at AS last_used_at
       FROM link_devices d JOIN users u ON u.id = d.user_id
       WHERE d.token_hash = ?1 AND d.revoked_at IS NULL`,
    )
    .bind(tokenHash)
    .first<{ user_id: string; device_id: string; last_used_at: number | null }>();
  if (!row) return null;
  const now = Date.now();
  if (row.last_used_at === null || now - row.last_used_at > 3_600_000) {
    await db.prepare("UPDATE link_devices SET last_used_at = ?1 WHERE token_hash = ?2").bind(now, tokenHash).run();
  }
  return { userId: row.user_id, deviceId: row.device_id };
}

/** Accept either the Mac's app token (role mac) or a phone token (role phone). */
export async function authenticateLinkPrincipal(db: D1Database, request: Request): Promise<LinkPrincipal | null> {
  const mac = await authenticateAppToken(db, request);
  if (mac) return { userId: mac.userId, role: "mac" };
  const phone = await authenticateLinkToken(db, request);
  if (phone) return { userId: phone.userId, role: "phone" };
  return null;
}

// ---------------------------------------------------------------------------------------------
// Blobs

/** Read a link blob; null if missing or older than LINK_BLOB_TTL_MS (the lifecycle rule may lag). */
export async function getLinkBlob(bucket: R2Bucket, userId: string, blobId: string, now = Date.now()): Promise<R2ObjectBody | null> {
  const object = await bucket.get(linkBlobKey(userId, blobId));
  if (!object) return null;
  const uploadedAt = Number(object.customMetadata?.uploadedAt ?? object.uploaded.getTime());
  if (!Number.isFinite(uploadedAt) || now - uploadedAt > LINK_BLOB_TTL_MS) {
    await object.body.cancel();
    return null;
  }
  return object;
}
