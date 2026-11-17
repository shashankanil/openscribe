import { z } from "zod";

/** Normalized document, exactly as in docs/CONTEXT-API.md. */
export interface OpenScribeDocument {
  id: string;
  kind: "note" | "meeting";
  title: string;
  createdAt: string;
  updatedAt: string;
  deleted: boolean;
  body: string;
  summary: string | null;
  transcript: string | null;
  actionItems: string[];
  durationSeconds: number;
  tags: string[];
}

export const MAX_DOCUMENTS_PER_BATCH = 200;
export const MAX_BATCH_BYTES = 5 * 1024 * 1024;
/** D1 rows are capped at 2 MB; keep a margin for the other columns. */
export const MAX_DOCUMENT_BYTES = 1_900_000;

const isoDate = z
  .string()
  .max(64)
  .refine((v) => !Number.isNaN(Date.parse(v)), "must be an ISO-8601 date");

export const documentSchema = z.object({
  id: z.string().min(1).max(200),
  kind: z.enum(["note", "meeting"]),
  title: z.string().max(2_000).default(""),
  createdAt: isoDate,
  updatedAt: isoDate,
  deleted: z.boolean().default(false),
  body: z.string().nullish().transform((v) => v ?? ""),
  summary: z.string().nullish().transform((v) => v ?? null),
  transcript: z.string().nullish().transform((v) => v ?? null),
  actionItems: z.array(z.string().max(10_000)).max(1_000).nullish().transform((v) => v ?? []),
  durationSeconds: z.number().finite().min(0).nullish().transform((v) => v ?? 0),
  tags: z.array(z.string().max(200)).max(200).nullish().transform((v) => v ?? []),
});

export interface DocumentRow {
  id: string;
  kind: "note" | "meeting";
  title: string;
  created_at: number;
  updated_at: number;
  deleted: number;
  body: string;
  summary: string | null;
  transcript: string | null;
  action_items: string;
  duration_seconds: number;
  tags: string;
}

export const DOCUMENT_COLUMNS =
  "id, kind, title, created_at, updated_at, deleted, body, summary, transcript, action_items, duration_seconds, tags";

function parseStringArray(json: string): string[] {
  try {
    const value: unknown = JSON.parse(json);
    return Array.isArray(value) ? value.filter((v): v is string => typeof v === "string") : [];
  } catch {
    return [];
  }
}

export function rowToDocument(row: DocumentRow): OpenScribeDocument {
  return {
    id: row.id,
    kind: row.kind,
    title: row.title,
    createdAt: new Date(row.created_at).toISOString(),
    updatedAt: new Date(row.updated_at).toISOString(),
    deleted: row.deleted !== 0,
    body: row.body,
    summary: row.summary,
    transcript: row.transcript,
    actionItems: parseStringArray(row.action_items),
    durationSeconds: row.duration_seconds,
    tags: parseStringArray(row.tags),
  };
}

export interface BatchResult {
  accepted: number;
  skipped: number;
  errors: { index: number; id?: string; error: string }[];
}

const UPSERT_SQL = `
INSERT INTO documents (user_id, id, kind, title, created_at, updated_at, deleted, body, summary,
                       transcript, action_items, duration_seconds, tags, synced_at)
VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
ON CONFLICT (user_id, id) DO UPDATE SET
  kind = excluded.kind,
  title = excluded.title,
  created_at = excluded.created_at,
  updated_at = excluded.updated_at,
  deleted = excluded.deleted,
  body = excluded.body,
  summary = excluded.summary,
  transcript = excluded.transcript,
  action_items = excluded.action_items,
  duration_seconds = excluded.duration_seconds,
  tags = excluded.tags,
  synced_at = excluded.synced_at
WHERE excluded.updated_at > documents.updated_at`;

/**
 * Upsert documents for one user. A stored document is replaced only when the incoming
 * `updatedAt` is strictly newer. `deleted: true` stores a content-free tombstone.
 * Invalid entries are skipped and reported in `errors`; they never fail the batch.
 */
export async function upsertDocuments(
  db: D1Database,
  userId: string,
  input: unknown[],
  now = Date.now(),
): Promise<BatchResult> {
  const result: BatchResult = { accepted: 0, skipped: 0, errors: [] };
  const statements: D1PreparedStatement[] = [];
  const stmt = db.prepare(UPSERT_SQL);

  input.forEach((raw, index) => {
    const parsed = documentSchema.safeParse(raw);
    const rawId = typeof (raw as { id?: unknown })?.id === "string" ? (raw as { id: string }).id : undefined;
    if (!parsed.success) {
      result.skipped++;
      result.errors.push({ index, id: rawId, error: parsed.error.issues.map((i) => `${i.path.join(".")}: ${i.message}`).join("; ") });
      return;
    }
    const d = parsed.data;
    const tomb = d.deleted;
    const values = [
      userId,
      d.id,
      d.kind,
      tomb ? "" : d.title,
      Date.parse(d.createdAt),
      Date.parse(d.updatedAt),
      tomb ? 1 : 0,
      tomb ? "" : d.body,
      tomb ? null : d.summary,
      tomb ? null : d.transcript,
      JSON.stringify(tomb ? [] : d.actionItems),
      tomb ? 0 : d.durationSeconds,
      JSON.stringify(tomb ? [] : d.tags),
      now,
    ] as const;
    const size = values.reduce<number>((n, v) => n + (typeof v === "string" ? v.length * 3 : 8), 0);
    if (size > MAX_DOCUMENT_BYTES) {
      result.skipped++;
      result.errors.push({ index, id: d.id, error: "document too large" });
      return;
    }
    statements.push(stmt.bind(...values));
  });

  if (statements.length > 0) {
    const results = await db.batch(statements);
    for (const r of results) {
      if ((r.meta.changes ?? 0) > 0) result.accepted++;
      else result.skipped++;
    }
  }
  await db.prepare("UPDATE users SET last_sync_at = ?1 WHERE id = ?2").bind(now, userId).run();
  return result;
}

/** Tombstone a single document. Creates the tombstone if the id is unknown, so stale uploads can't resurrect it. */
export async function deleteDocument(db: D1Database, userId: string, id: string, now = Date.now()): Promise<void> {
  await db
    .prepare(
      `INSERT INTO documents (user_id, id, kind, title, created_at, updated_at, deleted, body, summary,
                              transcript, action_items, duration_seconds, tags, synced_at)
       VALUES (?1, ?2, 'note', '', ?3, ?3, 1, '', NULL, NULL, '[]', 0, '[]', ?3)
       ON CONFLICT (user_id, id) DO UPDATE SET
         title = '', deleted = 1, body = '', summary = NULL, transcript = NULL,
         action_items = '[]', duration_seconds = 0, tags = '[]',
         updated_at = MAX(documents.updated_at, excluded.updated_at), synced_at = excluded.synced_at`,
    )
    .bind(userId, id, now)
    .run();
}
