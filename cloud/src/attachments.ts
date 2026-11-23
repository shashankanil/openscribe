/**
 * Screenshots and meeting recordings. Bytes live in R2 (`MEDIA`) at u/{userId}/{documentId}/{id};
 * the `attachments` table holds metadata, drives quota, and scopes every lookup by user.
 */

export type AttachmentKind = "screenshot" | "recording";

export const MAX_ATTACHMENT_BYTES = 95 * 1024 * 1024;
export const MAX_CAPTION_CHARS = 500;

/** Allowed upload types → file extension. Screenshots must be image/*, recordings audio/*. */
export const MEDIA_TYPES: Record<string, string> = {
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/heic": "heic",
  "audio/mp4": "m4a",
  "audio/m4a": "m4a",
  "audio/aac": "aac",
  "audio/mpeg": "mp3",
};

/** Ids become R2 key segments, so they can't contain "/" or control characters. */
const ID_PATTERN = /^[^/\x00-\x1f\x7f]{1,200}$/;
export const isValidId = (id: string | undefined): id is string => typeof id === "string" && ID_PATTERN.test(id);

export const r2Key = (userId: string, documentId: string, attachmentId: string) => `u/${userId}/${documentId}/${attachmentId}`;
export const userPrefix = (userId: string) => `u/${userId}/`;

export interface AttachmentRow {
  document_id: string;
  id: string;
  kind: AttachmentKind;
  content_type: string;
  bytes: number;
  sha256: string;
  r2_key: string;
  created_at: number;
  duration_seconds: number;
  caption: string;
}

export const ATTACHMENT_COLUMNS = "document_id, id, kind, content_type, bytes, sha256, r2_key, created_at, duration_seconds, caption";

export async function getAttachmentRow(db: D1Database, userId: string, documentId: string, id: string): Promise<AttachmentRow | null> {
  return db
    .prepare(`SELECT ${ATTACHMENT_COLUMNS} FROM attachments WHERE user_id = ?1 AND document_id = ?2 AND id = ?3`)
    .bind(userId, documentId, id)
    .first<AttachmentRow>();
}

export async function listAttachmentRows(db: D1Database, userId: string, documentId?: string): Promise<AttachmentRow[]> {
  const res = documentId
    ? await db
        .prepare(`SELECT ${ATTACHMENT_COLUMNS} FROM attachments WHERE user_id = ?1 AND document_id = ?2 ORDER BY created_at, id`)
        .bind(userId, documentId)
        .all<AttachmentRow>()
    : await db
        .prepare(`SELECT ${ATTACHMENT_COLUMNS} FROM attachments WHERE user_id = ?1 ORDER BY document_id, created_at, id`)
        .bind(userId)
        .all<AttachmentRow>();
  return res.results;
}

export async function usedBytes(db: D1Database, userId: string, excluding?: { documentId: string; id: string }): Promise<number> {
  const row = await db
    .prepare("SELECT COALESCE(SUM(bytes), 0) AS total FROM attachments WHERE user_id = ?1 AND NOT (document_id = ?2 AND id = ?3)")
    .bind(userId, excluding?.documentId ?? "", excluding?.id ?? "")
    .first<{ total: number }>();
  return row?.total ?? 0;
}

export interface AttachmentInput {
  documentId: string;
  id: string;
  kind: AttachmentKind;
  contentType: string;
  bytes: number;
  sha256: string;
  createdAt: number;
  durationSeconds: number;
  caption: string;
}

export async function upsertAttachmentRow(db: D1Database, userId: string, a: AttachmentInput, now = Date.now()): Promise<void> {
  await db
    .prepare(
      `INSERT INTO attachments (user_id, document_id, id, kind, content_type, bytes, sha256, r2_key, created_at,
                                duration_seconds, caption, uploaded_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
       ON CONFLICT (user_id, document_id, id) DO UPDATE SET
         kind = excluded.kind, content_type = excluded.content_type, bytes = excluded.bytes, sha256 = excluded.sha256,
         r2_key = excluded.r2_key, created_at = excluded.created_at, duration_seconds = excluded.duration_seconds,
         caption = excluded.caption, uploaded_at = excluded.uploaded_at`,
    )
    .bind(userId, a.documentId, a.id, a.kind, a.contentType, a.bytes, a.sha256, r2Key(userId, a.documentId, a.id), a.createdAt, a.durationSeconds, a.caption, now)
    .run();
}

/** Metadata-only update for a re-upload of identical bytes; undefined fields are left as they are. */
export async function updateAttachmentMetadata(
  db: D1Database,
  userId: string,
  documentId: string,
  id: string,
  a: Partial<Pick<AttachmentInput, "kind" | "createdAt" | "durationSeconds" | "caption">>,
): Promise<void> {
  await db
    .prepare(
      `UPDATE attachments SET kind = COALESCE(?4, kind), created_at = COALESCE(?5, created_at),
         duration_seconds = COALESCE(?6, duration_seconds), caption = COALESCE(?7, caption)
       WHERE user_id = ?1 AND document_id = ?2 AND id = ?3`,
    )
    .bind(userId, documentId, id, a.kind ?? null, a.createdAt ?? null, a.durationSeconds ?? null, a.caption ?? null)
    .run();
}

export async function deleteAttachment(env: Env, userId: string, documentId: string, id: string): Promise<void> {
  await env.MEDIA.delete(r2Key(userId, documentId, id));
  await env.DB.prepare("DELETE FROM attachments WHERE user_id = ?1 AND document_id = ?2 AND id = ?3").bind(userId, documentId, id).run();
}

/** Remove attachments (rows + objects) of the given documents that are currently tombstoned. */
export async function purgeTombstonedAttachments(env: Env, userId: string, documentIds: string[]): Promise<number> {
  let removed = 0;
  // Stay well under D1's bound-parameter limit.
  for (let i = 0; i < documentIds.length; i += 50) {
    const ids = documentIds.slice(i, i + 50);
    const placeholders = ids.map((_, j) => `?${j + 2}`).join(", ");
    const res = await env.DB.prepare(
      `SELECT a.document_id, a.id, a.r2_key FROM attachments a
       JOIN documents d ON d.user_id = a.user_id AND d.id = a.document_id
       WHERE a.user_id = ?1 AND d.deleted = 1 AND a.document_id IN (${placeholders})`,
    )
      .bind(userId, ...ids)
      .all<{ document_id: string; id: string; r2_key: string }>();
    if (res.results.length === 0) continue;
    await env.MEDIA.delete(res.results.map((r) => r.r2_key));
    const del = env.DB.prepare("DELETE FROM attachments WHERE user_id = ?1 AND document_id = ?2 AND id = ?3");
    await env.DB.batch(res.results.map((r) => del.bind(userId, r.document_id, r.id)));
    removed += res.results.length;
  }
  return removed;
}

/** Delete every R2 object under u/{userId}/ (pages of 1000). Rows are deleted by the caller. */
export async function purgeUserMedia(bucket: R2Bucket, userId: string): Promise<void> {
  await purgePrefix(bucket, userPrefix(userId));
}

/** Delete every R2 object under `prefix` (pages of 1000). */
export async function purgePrefix(bucket: R2Bucket, prefix: string): Promise<void> {
  for (;;) {
    // Always list from the start: the previous page is gone, so no cursor is needed.
    const page = await bucket.list({ prefix, limit: 1000 });
    if (page.objects.length === 0) break;
    await bucket.delete(page.objects.map((o) => o.key));
    if (!page.truncated) break;
  }
}

export function attachmentFilename(title: string, row: Pick<AttachmentRow, "id" | "content_type">): string {
  const base = title.normalize("NFKD").replace(/[^A-Za-z0-9 ._-]+/g, "").trim().replace(/\s+/g, " ").slice(0, 80);
  const ext = MEDIA_TYPES[row.content_type] ?? "bin";
  const id = row.id.replace(/[^A-Za-z0-9._-]+/g, "").slice(0, 8);
  return `${[base, id].filter(Boolean).join(" ") || "attachment"}.${ext}`;
}
