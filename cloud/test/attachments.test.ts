import { env, exports } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { MAX_ATTACHMENT_BYTES, r2Key } from "../src/attachments";
import { base64 } from "../src/crypto";
import { signMediaToken, verifyMediaToken } from "../src/media";
import { fetchDocument, getAttachment, getMeeting } from "../src/tools";
import { BASE, makeDoc, media, resetDb, seedUserWithToken } from "./helpers";

const worker = exports.default;
const call = (path: string, init?: RequestInit) => worker.fetch(new Request(`${BASE}${path}`, { redirect: "manual", ...init }));
const auth = (token: string) => ({ Authorization: `Bearer ${token}` });

/** A valid 1×1 PNG. */
const PNG = Uint8Array.from(atob("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="), (c) => c.charCodeAt(0));
const AUDIO = Uint8Array.from({ length: 4096 }, (_, i) => i % 251);

async function sha256(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

interface UploadOptions {
  contentType?: string;
  kind?: string;
  sha?: string;
  headers?: Record<string, string>;
}

async function upload(token: string, documentId: string, id: string, bytes: Uint8Array, opts: UploadOptions = {}) {
  const headers: Record<string, string> = {
    ...auth(token),
    "Content-Type": opts.contentType ?? "image/png",
    "Content-Length": String(bytes.byteLength),
    "X-OpenScribe-Kind": opts.kind ?? "screenshot",
    "X-OpenScribe-Sha256": opts.sha ?? (await sha256(bytes)),
    ...opts.headers,
  };
  return call(`/api/v1/attachments/${encodeURIComponent(documentId)}/${encodeURIComponent(id)}`, { method: "PUT", body: bytes, headers });
}

async function syncDocs(token: string, documents: unknown[]) {
  const res = await call("/api/v1/documents/batch", {
    method: "POST",
    headers: { ...auth(token), "Content-Type": "application/json" },
    body: JSON.stringify({ documents }),
  });
  expect(res.status).toBe(200);
}

const mediaPath = (url: string) => new URL(url).pathname;

let token: string;
const U = "media-user";

beforeEach(async () => {
  await resetDb(env.DB);
  token = await seedUserWithToken(env.DB, U);
  await syncDocs(token, [
    makeDoc({ id: "meet-1", kind: "meeting", title: "Design sync", createdAt: "2026-11-01T10:00:00.000Z", updatedAt: "2026-11-01T10:00:00.000Z" }),
    makeDoc({ id: "note-1", title: "Whiteboard", updatedAt: "2026-11-01T10:00:00.000Z" }),
  ]);
});

describe("attachment upload API", () => {
  it("uploads, dedupes by sha256, lists, and reports usage in /me", async () => {
    const res = await upload(token, "meet-1", "shot-1", PNG, {
      headers: { "X-OpenScribe-Created-At": "2026-11-01T10:05:00Z", "X-OpenScribe-Caption": encodeURIComponent("Roadmap slide — Q3 ✓") },
    });
    expect(res.status).toBe(201);
    const sha = await sha256(PNG);
    expect(await res.json()).toEqual({ id: "shot-1", documentId: "meet-1", kind: "screenshot", bytes: PNG.byteLength, sha256: sha });
    expect((await env.MEDIA.head(r2Key(U, "meet-1", "shot-1")))?.size).toBe(PNG.byteLength);

    const again = await upload(token, "meet-1", "shot-1", PNG);
    expect(again.status).toBe(200);

    const rec = await upload(token, "meet-1", "rec-1", AUDIO, { contentType: "audio/mp4", kind: "recording", headers: { "X-OpenScribe-Duration": "1830.5" } });
    expect(rec.status).toBe(201);

    const list = (await (await call("/api/v1/attachments", { headers: auth(token) })).json()) as { attachments: unknown[] };
    expect(list.attachments).toEqual([
      { id: "rec-1", documentId: "meet-1", kind: "recording", contentType: "audio/mp4", bytes: AUDIO.byteLength, sha256: await sha256(AUDIO), createdAt: expect.any(String) },
      { id: "shot-1", documentId: "meet-1", kind: "screenshot", contentType: "image/png", bytes: PNG.byteLength, sha256: sha, createdAt: "2026-11-01T10:05:00.000Z" },
    ].sort((a, b) => a.createdAt.localeCompare(b.createdAt)));

    const me = (await (await call("/api/v1/me", { headers: auth(token) })).json()) as Record<string, unknown>;
    expect(me).toMatchObject({ attachmentCount: 2, attachmentBytes: PNG.byteLength + AUDIO.byteLength });

    const row = await env.DB.prepare("SELECT caption, duration_seconds FROM attachments WHERE id = 'rec-1' OR id = 'shot-1' ORDER BY id").all();
    expect(row.results).toEqual([{ caption: "", duration_seconds: 1830.5 }, { caption: "Roadmap slide — Q3 ✓", duration_seconds: 0 }]);
  });

  it("validates headers, size, and the document", async () => {
    expect((await upload(token, "meet-1", "a", PNG, { contentType: "image/gif" })).status).toBe(415);
    expect((await upload(token, "meet-1", "a", PNG, { kind: "video" })).status).toBe(400);
    expect((await upload(token, "meet-1", "a", PNG, { kind: "recording" })).status).toBe(400);
    expect((await upload(token, "meet-1", "a", PNG, { sha: "abc" })).status).toBe(400);
    expect((await upload(token, "meet-1", "a", PNG, { headers: { "X-OpenScribe-Created-At": "yesterday" } })).status).toBe(400);
    expect((await upload(token, "meet-1", "a", PNG, { headers: { "X-OpenScribe-Caption": "%E0%A4%A" } })).status).toBe(400);

    const tooLarge = await upload(token, "meet-1", "a", PNG, { headers: { "Content-Length": String(MAX_ATTACHMENT_BYTES + 1) } });
    expect(tooLarge.status).toBe(413);
    expect(await tooLarge.json()).toMatchObject({ error: "too_large" });

    const missing = await upload(token, "nope", "a", PNG);
    expect(missing.status).toBe(404);
    expect(await missing.json()).toMatchObject({ error: "document_not_found" });

    await call("/api/v1/documents/note-1", { method: "DELETE", headers: auth(token) });
    expect((await upload(token, "note-1", "a", PNG)).status).toBe(404);

    // Another user's document is invisible.
    const other = await seedUserWithToken(env.DB, "other-user");
    expect((await upload(other, "meet-1", "a", PNG)).status).toBe(404);
    expect((await call("/api/v1/attachments", { method: "GET" })).status).toBe(401);
  });

  it("truncates captions to 500 characters", async () => {
    expect((await upload(token, "meet-1", "a", PNG, { headers: { "X-OpenScribe-Caption": encodeURIComponent("é".repeat(600)) } })).status).toBe(201);
    const row = await env.DB.prepare("SELECT caption FROM attachments WHERE id = 'a'").first<{ caption: string }>();
    expect(row!.caption).toBe("é".repeat(500));
  });

  it("rejects a checksum mismatch without storing anything", async () => {
    const res = await upload(token, "meet-1", "bad", PNG, { sha: await sha256(AUDIO) });
    expect(res.status).toBe(400);
    expect(await res.json()).toMatchObject({ error: "checksum_mismatch" });
    expect(await env.MEDIA.head(r2Key(U, "meet-1", "bad"))).toBeNull();
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM attachments").first()).toEqual({ n: 0 });
  });

  it("enforces the per-user quota, excluding the attachment being replaced", async () => {
    const quota = Number(env.MEDIA_QUOTA_BYTES);
    await env.DB.prepare(
      `INSERT INTO attachments (user_id, document_id, id, kind, content_type, bytes, sha256, r2_key, created_at, uploaded_at)
       VALUES (?1, 'meet-1', 'big', 'recording', 'audio/mp4', ?2, 'x', 'k', 0, 0)`,
    )
      .bind(U, quota - PNG.byteLength + 1)
      .run();
    const res = await upload(token, "meet-1", "shot", PNG);
    expect(res.status).toBe(413);
    expect(await res.json()).toMatchObject({ error: "quota_exceeded" });
    // Replacing "big" itself only counts the new size.
    expect((await upload(token, "meet-1", "big", AUDIO, { contentType: "audio/mp4", kind: "recording" })).status).toBe(201);
  });

  it("deletes one attachment idempotently", async () => {
    await upload(token, "meet-1", "shot-1", PNG);
    for (let i = 0; i < 2; i++) {
      expect((await call("/api/v1/attachments/meet-1/shot-1", { method: "DELETE", headers: auth(token) })).status).toBe(204);
    }
    expect(await env.MEDIA.head(r2Key(U, "meet-1", "shot-1"))).toBeNull();
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM attachments").first()).toEqual({ n: 0 });
  });

  it("removes attachments when a document is tombstoned", async () => {
    await upload(token, "meet-1", "shot-1", PNG);
    await upload(token, "meet-1", "rec-1", AUDIO, { contentType: "audio/mp4", kind: "recording" });
    await upload(token, "note-1", "shot-2", PNG);

    // A stale tombstone (older updatedAt) is ignored and must not delete anything.
    await syncDocs(token, [makeDoc({ id: "meet-1", kind: "meeting", deleted: true, updatedAt: "2026-10-01T00:00:00.000Z" })]);
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM attachments").first()).toEqual({ n: 3 });

    await syncDocs(token, [makeDoc({ id: "meet-1", kind: "meeting", deleted: true, updatedAt: "2026-11-02T00:00:00.000Z" })]);
    expect(await env.MEDIA.head(r2Key(U, "meet-1", "shot-1"))).toBeNull();
    expect(await env.MEDIA.head(r2Key(U, "meet-1", "rec-1"))).toBeNull();
    const left = await env.DB.prepare("SELECT id FROM attachments").all<{ id: string }>();
    expect(left.results.map((r) => r.id)).toEqual(["shot-2"]);

    // DELETE /documents/:id does the same.
    await call("/api/v1/documents/note-1", { method: "DELETE", headers: auth(token) });
    expect(await env.MEDIA.head(r2Key(U, "note-1", "shot-2"))).toBeNull();
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM attachments").first()).toEqual({ n: 0 });
  });

  it("account deletion removes every object under the user's prefix", async () => {
    await upload(token, "meet-1", "shot-1", PNG);
    await env.MEDIA.put(`u/${U}/orphan/x`, "stray");
    await env.MEDIA.put("u/someone-else/doc/x", "keep");
    expect((await call("/api/v1/account", { method: "DELETE", headers: auth(token) })).status).toBe(200);
    expect((await env.MEDIA.list({ prefix: `u/${U}/` })).objects).toEqual([]);
    expect(await env.MEDIA.head("u/someone-else/doc/x")).not.toBeNull();
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM attachments").first()).toEqual({ n: 0 });
    await env.MEDIA.delete("u/someone-else/doc/x");
  });
});

describe("signed media URLs", () => {
  it("serves bytes with range support, and rejects tampered or expired tokens", async () => {
    await upload(token, "meet-1", "rec-1", AUDIO, { contentType: "audio/mp4", kind: "recording" });
    const { structured } = await fetchDocument(env.DB, U, { id: "meet-1" }, media(U));
    const url = structured.attachments[0]!.url;
    expect(url.startsWith(`${BASE}/media/`)).toBe(true);

    const full = await call(mediaPath(url));
    expect(full.status).toBe(200);
    expect(new Uint8Array(await full.arrayBuffer())).toEqual(AUDIO);
    expect(full.headers.get("Content-Type")).toBe("audio/mp4");
    expect(full.headers.get("Accept-Ranges")).toBe("bytes");
    expect(full.headers.get("Cache-Control")).toBe("private, max-age=3600");
    expect(full.headers.get("X-Content-Type-Options")).toBe("nosniff");
    expect(full.headers.get("Content-Disposition")).toBe('inline; filename="Design sync rec-1.m4a"');

    const part = await call(mediaPath(url), { headers: { Range: "bytes=10-19" } });
    expect(part.status).toBe(206);
    expect(part.headers.get("Content-Range")).toBe(`bytes 10-19/${AUDIO.byteLength}`);
    expect(new Uint8Array(await part.arrayBuffer())).toEqual(AUDIO.slice(10, 20));

    const suffix = await call(mediaPath(url), { headers: { Range: "bytes=-5" } });
    expect(suffix.status).toBe(206);
    expect(new Uint8Array(await suffix.arrayBuffer())).toEqual(AUDIO.slice(-5));

    const open = await call(mediaPath(url), { headers: { Range: `bytes=4000-` } });
    expect(open.headers.get("Content-Range")).toBe(`bytes 4000-4095/4096`);
    await open.arrayBuffer();

    const beyond = await call(mediaPath(url), { headers: { Range: "bytes=99999-" } });
    expect(beyond.status).toBe(416);
    expect(beyond.headers.get("Content-Range")).toBe(`bytes */${AUDIO.byteLength}`);

    // Tampered payload (another attachment) with the original signature.
    const [body, sig] = mediaPath(url).slice("/media/".length).split(".");
    const forged = btoa(JSON.stringify({ u: U, d: "meet-1", a: "other", exp: 9_999_999_999 })).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
    expect((await call(`/media/${forged}.${sig}`)).status).toBe(403);
    expect((await call(`/media/${body}.${sig!.slice(0, -2)}AA`)).status).toBe(403);
    expect((await call(`/media/garbage`)).status).toBe(403);

    const expired = await signMediaToken(env.COOKIE_ENCRYPTION_KEY, { u: U, d: "meet-1", a: "rec-1", exp: Math.floor(Date.now() / 1000) - 1 });
    expect((await call(`/media/${expired}`)).status).toBe(403);
    expect(await verifyMediaToken(env.COOKIE_ENCRYPTION_KEY, expired)).toBeNull();
    // A token signed with a different secret is rejected.
    const otherKey = await signMediaToken("another-secret-0123456789abcdef0123456789", { u: U, d: "meet-1", a: "rec-1", exp: 9_999_999_999 });
    expect((await call(`/media/${otherKey}`)).status).toBe(403);

    // A valid token for a deleted attachment stops working.
    await call("/api/v1/attachments/meet-1/rec-1", { method: "DELETE", headers: auth(token) });
    expect((await call(mediaPath(url))).status).toBe(404);
  });
});

describe("MCP attachment tools", () => {
  beforeEach(async () => {
    await upload(token, "meet-1", "shot-1", PNG, { headers: { "X-OpenScribe-Caption": "Whiteboard" } });
    await upload(token, "meet-1", "rec-1", AUDIO, { contentType: "audio/mp4", kind: "recording", headers: { "X-OpenScribe-Duration": "65" } });
  });

  it("fetch and get_meeting list attachments with signed URLs", async () => {
    const fetched = await fetchDocument(env.DB, U, { id: "meet-1" }, media(U));
    expect(fetched.structured.attachments.map((a) => a.id).sort()).toEqual(["rec-1", "shot-1"]);
    const shot = fetched.structured.attachments.find((a) => a.id === "shot-1")!;
    expect(shot).toMatchObject({ kind: "screenshot", contentType: "image/png", bytes: PNG.byteLength, caption: "Whiteboard", durationSeconds: 0 });
    expect(fetched.text).toContain("## Attachments");
    expect(fetched.text).toContain('screenshot `shot-1`');
    expect(fetched.text).toContain("get_attachment");

    const meeting = await getMeeting(env.DB, U, { id: "meet-1" }, media(U));
    const rec = meeting.structured.attachments.find((a) => a.id === "rec-1")!;
    expect(rec).toMatchObject({ kind: "recording", durationSeconds: 65 });
    expect(meeting.text).toContain("1m 5s");

    // Note without attachments.
    const note = await fetchDocument(env.DB, U, { id: "note-1" }, media(U));
    expect(note.structured.attachments).toEqual([]);
    expect(note.text).not.toContain("## Attachments");
  });

  it("get_attachment returns small screenshots inline and recordings as resource links", async () => {
    const image = await getAttachment(env.DB, U, { documentId: "meet-1", id: "shot-1" }, media(U));
    expect(image.content![0]).toEqual({ type: "image", data: base64(PNG), mimeType: "image/png" });
    expect(image.content![1]).toMatchObject({ type: "text", text: expect.stringContaining("Whiteboard") });

    const recording = await getAttachment(env.DB, U, { documentId: "meet-1", id: "rec-1" }, media(U));
    expect(recording.content![0]).toMatchObject({ type: "text", text: expect.stringContaining("/media/") });
    const link = recording.content![1] as { type: string; uri: string; mimeType: string; size: number; name: string };
    expect(link).toMatchObject({ type: "resource_link", mimeType: "audio/mp4", size: AUDIO.byteLength, name: "Design sync rec-1.m4a" });
    expect((await call(mediaPath(link.uri))).status).toBe(200);

    await expect(getAttachment(env.DB, U, { documentId: "meet-1", id: "nope" }, media(U))).rejects.toThrow(/No attachment/);
    await expect(getAttachment(env.DB, "other", { documentId: "meet-1", id: "shot-1" }, media("other"))).rejects.toThrow(/No attachment/);
  });

  it("base64 matches btoa for buffers larger than one chunk", () => {
    const big = Uint8Array.from({ length: 100_003 }, (_, i) => (i * 7) % 256);
    let binary = "";
    for (const b of big) binary += String.fromCharCode(b);
    expect(base64(big)).toBe(btoa(binary));
  });
});
