/**
 * MCP tool logic as pure functions over (db, userId, args). The MCP server in mcp.ts only
 * adapts these to the protocol, so they can be tested against a seeded D1 without OAuth.
 * Every query is scoped by user_id and excludes tombstones. Tools that expose attachments also
 * take a per-user `MediaAccess` (R2 bucket + signed URL builder).
 */
import { attachmentFilename, getAttachmentRow, listAttachmentRows, type AttachmentKind, type AttachmentRow } from "./attachments";
import { base64 } from "./crypto";
import { DOCUMENT_COLUMNS, rowToDocument, type DocumentRow, type OpenScribeDocument } from "./documents";
import type { MediaAccess } from "./media";

export const TRANSCRIPT_CHAR_LIMIT = 60_000;
const DAY_MS = 86_400_000;

export type Kind = "note" | "meeting";

export class ToolError extends Error {}

/** The MCP content blocks these tools produce (a subset of the SDK's ContentBlock). */
export type ContentItem =
  | { type: "text"; text: string }
  | { type: "image"; data: string; mimeType: string }
  | { type: "resource_link"; uri: string; name: string; title?: string; description?: string; mimeType: string; size: number };

export interface ToolResult<T> {
  /** Text content for the model. */
  text: string;
  /** Structured content (MCP `structuredContent`). */
  structured: T;
  /** Full content, when it is more than `text` alone. */
  content?: ContentItem[];
}

const clamp = (value: number | undefined, fallback: number, min: number, max: number) =>
  Math.min(max, Math.max(min, Math.trunc(value ?? fallback)));

// ---------------------------------------------------------------------------------------------
// search

export interface SearchArgs {
  query: string;
  kind?: Kind;
  limit?: number;
}

export interface SearchHit {
  id: string;
  kind: Kind;
  title: string;
  createdAt: string;
  snippet: string;
}

/** Turn free text into a safe FTS5 query: quoted prefix terms, joined by AND or OR. */
export function buildFtsQuery(query: string, mode: "and" | "or"): string | null {
  const terms = query.normalize("NFKC").match(/[\p{L}\p{N}]+/gu)?.slice(0, 16) ?? [];
  if (terms.length === 0) return null;
  return terms.map((t) => `"${t}"*`).join(mode === "and" ? " " : " OR ");
}

const SEARCH_SQL = (withKind: boolean) => `
SELECT d.id, d.kind, d.title, d.created_at,
       snippet(documents_fts, -1, '**', '**', ' … ', 24) AS snippet,
       bm25(documents_fts, 10.0, 4.0, 3.0, 1.0, 5.0, 3.0) AS score
FROM documents_fts
JOIN documents d ON d.pk = documents_fts.rowid
WHERE documents_fts MATCH ?1 AND d.user_id = ?2 AND d.deleted = 0 ${withKind ? "AND d.kind = ?4" : ""}
ORDER BY score
LIMIT ?3`;

export async function search(db: D1Database, userId: string, args: SearchArgs): Promise<ToolResult<{ results: SearchHit[] }>> {
  const limit = clamp(args.limit, 10, 1, 50);
  let rows: { id: string; kind: Kind; title: string; created_at: number; snippet: string }[] = [];
  // Precise first (all terms), then broaden (any term) if nothing matched.
  for (const mode of ["and", "or"] as const) {
    const fts = buildFtsQuery(args.query, mode);
    if (!fts) break;
    const params: unknown[] = [fts, userId, limit];
    if (args.kind) params.push(args.kind);
    const res = await db.prepare(SEARCH_SQL(Boolean(args.kind))).bind(...params).all<(typeof rows)[number]>();
    rows = res.results;
    if (rows.length > 0) break;
  }
  const results = rows.map((r) => ({
    id: r.id,
    kind: r.kind,
    title: r.title,
    createdAt: new Date(r.created_at).toISOString(),
    snippet: r.snippet ?? "",
  }));
  return { text: JSON.stringify({ results }), structured: { results } };
}

// ---------------------------------------------------------------------------------------------
// shared helpers

async function getDocument(db: D1Database, userId: string, id: string): Promise<OpenScribeDocument | null> {
  const row = await db
    .prepare(`SELECT ${DOCUMENT_COLUMNS} FROM documents WHERE user_id = ?1 AND id = ?2 AND deleted = 0`)
    .bind(userId, id)
    .first<DocumentRow>();
  return row ? rowToDocument(row) : null;
}

export function truncateTranscript(transcript: string | null): string | null {
  if (transcript === null || transcript.length <= TRANSCRIPT_CHAR_LIMIT) return transcript;
  return (
    transcript.slice(0, TRANSCRIPT_CHAR_LIMIT) +
    `\n\n[Transcript truncated at ${TRANSCRIPT_CHAR_LIMIT.toLocaleString("en-US")} of ${transcript.length.toLocaleString("en-US")} characters. ` +
    `Call get_meeting for a narrower result (summary, action items and notes), or use search to find specific passages.]`
  );
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

function formatDuration(seconds: number): string {
  const total = Math.round(seconds);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  if (h > 0) return `${h}h ${m}m`;
  if (m > 0) return `${m}m ${s}s`;
  return `${s}s`;
}

// ---------------------------------------------------------------------------------------------
// attachments

export interface AttachmentInfo {
  id: string;
  kind: AttachmentKind;
  contentType: string;
  bytes: number;
  createdAt: string;
  durationSeconds: number;
  caption: string;
  /** Signed media URL, valid for one hour. */
  url: string;
}

async function toAttachmentInfo(row: AttachmentRow, media: MediaAccess): Promise<AttachmentInfo> {
  return {
    id: row.id,
    kind: row.kind,
    contentType: row.content_type,
    bytes: row.bytes,
    createdAt: new Date(row.created_at).toISOString(),
    durationSeconds: row.duration_seconds,
    caption: row.caption,
    url: await media.url(row.document_id, row.id),
  };
}

async function documentAttachments(db: D1Database, userId: string, documentId: string, media: MediaAccess): Promise<AttachmentInfo[]> {
  return Promise.all((await listAttachmentRows(db, userId, documentId)).map((row) => toAttachmentInfo(row, media)));
}

function describeAttachment(a: AttachmentInfo): string {
  const parts = [a.contentType, formatBytes(a.bytes)];
  if (a.kind === "recording" && a.durationSeconds > 0) parts.push(formatDuration(a.durationSeconds));
  parts.push(a.createdAt);
  return `${a.kind} \`${a.id}\` (${parts.join(", ")})${a.caption ? ` "${a.caption}"` : ""}`;
}

function attachmentsMarkdown(documentId: string, attachments: AttachmentInfo[]): string[] {
  if (attachments.length === 0) return [];
  return [
    "## Attachments",
    "",
    ...attachments.map((a) => `- ${describeAttachment(a)}: ${a.url}`),
    "",
    `Call get_attachment with documentId "${documentId}" and an attachment id to view it. URLs expire in one hour.`,
    "",
  ];
}

/** Render a document as markdown for the model. */
export function documentToMarkdown(
  doc: OpenScribeDocument,
  opts: { includeTranscript?: boolean; attachments?: AttachmentInfo[] } = {},
): string {
  const lines: string[] = [`# ${doc.title || "Untitled"}`, ""];
  const meta = [`Kind: ${doc.kind}`, `Created: ${doc.createdAt}`, `Updated: ${doc.updatedAt}`, `ID: ${doc.id}`];
  if (doc.kind === "meeting" && doc.durationSeconds > 0) meta.push(`Duration: ${formatDuration(doc.durationSeconds)}`);
  if (doc.tags.length) meta.push(`Tags: ${doc.tags.join(", ")}`);
  lines.push(meta.join(" · "), "");
  if (doc.summary) lines.push("## Summary", "", doc.summary, "");
  if (doc.actionItems.length) lines.push("## Action items", "", ...doc.actionItems.map((a) => `- [ ] ${a}`), "");
  if (doc.body) lines.push(doc.kind === "meeting" ? "## Notes" : "## Note", "", doc.body, "");
  lines.push(...attachmentsMarkdown(doc.id, opts.attachments ?? []));
  if (opts.includeTranscript !== false && doc.transcript) lines.push("## Transcript", "", truncateTranscript(doc.transcript)!, "");
  return lines.join("\n").trimEnd() + "\n";
}

// ---------------------------------------------------------------------------------------------
// fetch

export type FetchedDocument = OpenScribeDocument & { attachments: AttachmentInfo[] };

export async function fetchDocument(
  db: D1Database,
  userId: string,
  args: { id: string },
  media: MediaAccess,
): Promise<ToolResult<FetchedDocument>> {
  const doc = await getDocument(db, userId, args.id);
  if (!doc) throw new ToolError(`No document with id "${args.id}".`);
  const attachments = await documentAttachments(db, userId, doc.id, media);
  const structured = { ...doc, transcript: truncateTranscript(doc.transcript), attachments };
  return { text: documentToMarkdown(doc, { attachments }), structured };
}

// ---------------------------------------------------------------------------------------------
// list_recent

export interface ListRecentArgs {
  kind?: Kind;
  days?: number;
  limit?: number;
}

export type DocumentWithoutTranscript = Omit<OpenScribeDocument, "transcript">;

export async function listRecent(
  db: D1Database,
  userId: string,
  args: ListRecentArgs,
  now = Date.now(),
): Promise<ToolResult<{ documents: DocumentWithoutTranscript[] }>> {
  const days = clamp(args.days, 7, 1, 3650);
  const limit = clamp(args.limit, 20, 1, 100);
  const params: unknown[] = [userId, now - days * DAY_MS, limit];
  if (args.kind) params.push(args.kind);
  const res = await db
    .prepare(
      `SELECT ${DOCUMENT_COLUMNS} FROM documents
       WHERE user_id = ?1 AND deleted = 0 AND updated_at >= ?2 ${args.kind ? "AND kind = ?4" : ""}
       ORDER BY updated_at DESC LIMIT ?3`,
    )
    .bind(...params)
    .all<DocumentRow>();
  const documents = res.results.map((row) => {
    const { transcript: _omit, ...rest } = rowToDocument(row);
    return rest;
  });
  const text = documents.length
    ? documents
        .map((d) => documentToMarkdown({ ...d, transcript: null }, { includeTranscript: false }))
        .join("\n---\n\n")
    : `No ${args.kind ? `${args.kind}s` : "documents"} updated in the last ${days} days.`;
  return { text, structured: { documents } };
}

// ---------------------------------------------------------------------------------------------
// get_meeting

export interface MeetingResult {
  id: string;
  title: string;
  createdAt: string;
  updatedAt: string;
  durationSeconds: number;
  summary: string | null;
  actionItems: string[];
  notes: string;
  tags: string[];
  attachments: AttachmentInfo[];
  transcript?: string | null;
}

export async function getMeeting(
  db: D1Database,
  userId: string,
  args: { id: string; includeTranscript?: boolean },
  media: MediaAccess,
): Promise<ToolResult<MeetingResult>> {
  const doc = await getDocument(db, userId, args.id);
  if (!doc || doc.kind !== "meeting") throw new ToolError(`No meeting with id "${args.id}".`);
  const include = args.includeTranscript === true;
  const attachments = await documentAttachments(db, userId, doc.id, media);
  const structured: MeetingResult = {
    id: doc.id,
    title: doc.title,
    createdAt: doc.createdAt,
    updatedAt: doc.updatedAt,
    durationSeconds: doc.durationSeconds,
    summary: doc.summary,
    actionItems: doc.actionItems,
    notes: doc.body,
    tags: doc.tags,
    attachments,
    ...(include ? { transcript: truncateTranscript(doc.transcript) } : {}),
  };
  return { text: documentToMarkdown(doc, { includeTranscript: include, attachments }), structured };
}

// ---------------------------------------------------------------------------------------------
// list_action_items

export interface ActionItem {
  text: string;
  meetingId: string;
  meetingTitle: string;
  meetingDate: string;
}

export async function listActionItems(
  db: D1Database,
  userId: string,
  args: { days?: number },
  now = Date.now(),
): Promise<ToolResult<{ actionItems: ActionItem[] }>> {
  const days = clamp(args.days, 14, 1, 3650);
  const res = await db
    .prepare(
      `SELECT id, title, created_at, action_items FROM documents
       WHERE user_id = ?1 AND kind = 'meeting' AND deleted = 0 AND created_at >= ?2 AND action_items != '[]'
       ORDER BY created_at DESC LIMIT 500`,
    )
    .bind(userId, now - days * DAY_MS)
    .all<{ id: string; title: string; created_at: number; action_items: string }>();
  const actionItems: ActionItem[] = [];
  for (const row of res.results) {
    const doc = rowToDocument({ ...row, kind: "meeting", updated_at: row.created_at, deleted: 0, body: "", summary: null, transcript: null, duration_seconds: 0, tags: "[]" });
    for (const text of doc.actionItems) {
      actionItems.push({ text, meetingId: row.id, meetingTitle: row.title, meetingDate: doc.createdAt });
    }
  }
  const text = actionItems.length
    ? actionItems.map((a) => `- [ ] ${a.text} — ${a.meetingTitle || "Untitled meeting"} (${a.meetingDate.slice(0, 10)}, id ${a.meetingId})`).join("\n")
    : `No action items from meetings in the last ${days} days.`;
  return { text, structured: { actionItems } };
}

// ---------------------------------------------------------------------------------------------
// get_attachment

/** Screenshots up to this size are returned inline as MCP image content. */
export const INLINE_IMAGE_LIMIT = 5 * 1024 * 1024;
/** Image types MCP clients (and model APIs) reliably accept inline. HEIC goes out as a link. */
const INLINE_IMAGE_TYPES = new Set(["image/png", "image/jpeg"]);

export async function getAttachment(
  db: D1Database,
  userId: string,
  args: { documentId: string; id: string },
  media: MediaAccess,
): Promise<ToolResult<{ documentId: string; documentTitle: string; attachment: AttachmentInfo }>> {
  const doc = await getDocument(db, userId, args.documentId);
  const row = doc ? await getAttachmentRow(db, userId, args.documentId, args.id) : null;
  if (!doc || !row) throw new ToolError(`No attachment "${args.id}" on document "${args.documentId}".`);
  const attachment = await toAttachmentInfo(row, media);
  const structured = { documentId: doc.id, documentTitle: doc.title, attachment };
  const label = `${describeAttachment(attachment)} from ${doc.kind} "${doc.title || "Untitled"}" (${doc.id})`;

  if (row.kind === "screenshot" && INLINE_IMAGE_TYPES.has(row.content_type) && row.bytes <= INLINE_IMAGE_LIMIT) {
    const object = await media.bucket.get(row.r2_key);
    if (!object) throw new ToolError(`Attachment "${args.id}" is missing from storage.`);
    const data = base64(new Uint8Array(await object.arrayBuffer()));
    const text = `${label}\nSigned URL (expires in one hour): ${attachment.url}`;
    return { text, structured, content: [{ type: "image", data, mimeType: row.content_type }, { type: "text", text }] };
  }

  const hint =
    row.kind === "recording"
      ? doc.kind === "meeting"
        ? `The transcript is available from get_meeting with includeTranscript: true.`
        : ""
      : `This image is too large or in a format that isn't returned inline.`;
  const text = [label, `Signed URL (expires in one hour): ${attachment.url}`, hint].filter(Boolean).join("\n");
  return {
    text,
    structured,
    content: [
      { type: "text", text },
      {
        type: "resource_link",
        uri: attachment.url,
        name: attachmentFilename(doc.title, row),
        title: `${doc.title || "Untitled"} ${row.kind}`,
        ...(row.caption ? { description: row.caption } : {}),
        mimeType: row.content_type,
        size: row.bytes,
      },
    ],
  };
}
