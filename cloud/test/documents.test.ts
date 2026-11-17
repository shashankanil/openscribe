import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { upsertDocuments, deleteDocument } from "../src/documents";
import { fetchDocument, search } from "../src/tools";
import { makeDoc, media, resetDb, seedUser } from "./helpers";

beforeEach(() => resetDb(env.DB));

describe("migrations", () => {
  it("creates the schema including the FTS5 index", async () => {
    const { results } = await env.DB.prepare(
      "SELECT name FROM sqlite_master WHERE type IN ('table', 'trigger') ORDER BY name",
    ).all<{ name: string }>();
    const names = results.map((r) => r.name);
    for (const name of ["users", "app_tokens", "documents", "documents_fts", "documents_ai", "documents_au", "documents_ad", "attachments"]) {
      expect(names).toContain(name);
    }
  });
});

describe("batch upsert", () => {
  it("inserts, replaces only with a newer updatedAt, and tombstones", async () => {
    await seedUser(env.DB, "u1");
    const doc = makeDoc({ id: "doc-1", title: "Quarterly planning", body: "Budget for kiwi launch", updatedAt: "2026-01-01T00:00:00.000Z" });

    expect(await upsertDocuments(env.DB, "u1", [doc])).toMatchObject({ accepted: 1, skipped: 0 });

    // Same updatedAt: skipped (idempotent retry).
    expect(await upsertDocuments(env.DB, "u1", [{ ...doc, title: "Changed" }])).toMatchObject({ accepted: 0, skipped: 1 });

    // Older updatedAt: skipped, content unchanged.
    const older = { ...doc, title: "Stale", updatedAt: "2025-12-31T00:00:00.000Z" };
    expect(await upsertDocuments(env.DB, "u1", [older])).toMatchObject({ accepted: 0, skipped: 1 });
    expect((await fetchDocument(env.DB, "u1", { id: "doc-1" }, media("u1"))).structured.title).toBe("Quarterly planning");

    // Newer updatedAt: replaced, and the FTS index follows.
    const newer = { ...doc, title: "Annual planning", body: "Budget for mango launch", updatedAt: "2026-01-02T00:00:00.000Z" };
    expect(await upsertDocuments(env.DB, "u1", [newer])).toMatchObject({ accepted: 1, skipped: 0 });
    expect((await fetchDocument(env.DB, "u1", { id: "doc-1" }, media("u1"))).structured.title).toBe("Annual planning");
    expect((await search(env.DB, "u1", { query: "kiwi" })).structured.results).toHaveLength(0);
    expect((await search(env.DB, "u1", { query: "mango" })).structured.results).toHaveLength(1);

    // Tombstone: removed from search and fetch, content wiped.
    const tomb = { ...newer, deleted: true, updatedAt: "2026-01-03T00:00:00.000Z" };
    expect(await upsertDocuments(env.DB, "u1", [tomb])).toMatchObject({ accepted: 1 });
    expect((await search(env.DB, "u1", { query: "mango" })).structured.results).toHaveLength(0);
    await expect(fetchDocument(env.DB, "u1", { id: "doc-1" }, media("u1"))).rejects.toThrow(/No document/);
    const row = await env.DB.prepare("SELECT deleted, body, title FROM documents WHERE id = 'doc-1'").first();
    expect(row).toEqual({ deleted: 1, body: "", title: "" });

    // An older resurrection attempt after the tombstone is ignored; a newer one revives it.
    expect(await upsertDocuments(env.DB, "u1", [newer])).toMatchObject({ accepted: 0, skipped: 1 });
    const revived = { ...newer, updatedAt: "2026-01-04T00:00:00.000Z" };
    expect(await upsertDocuments(env.DB, "u1", [revived])).toMatchObject({ accepted: 1 });
    expect((await search(env.DB, "u1", { query: "mango" })).structured.results).toHaveLength(1);
  });

  it("skips invalid documents without failing the batch", async () => {
    await seedUser(env.DB, "u1");
    const good = makeDoc({ id: "ok" });
    const result = await upsertDocuments(env.DB, "u1", [good, { id: "bad", kind: "podcast" }, "nope"]);
    expect(result.accepted).toBe(1);
    expect(result.skipped).toBe(2);
    expect(result.errors.map((e) => e.index)).toEqual([1, 2]);
  });

  it("DELETE tombstones existing and unknown ids", async () => {
    await seedUser(env.DB, "u1");
    await upsertDocuments(env.DB, "u1", [makeDoc({ id: "a", body: "zebra", updatedAt: "2026-01-01T00:00:00.000Z" })]);
    await deleteDocument(env.DB, "u1", "a");
    await deleteDocument(env.DB, "u1", "never-synced");
    expect((await search(env.DB, "u1", { query: "zebra" })).structured.results).toHaveLength(0);
    // A stale upload of the unknown id can't resurrect it.
    const stale = makeDoc({ id: "never-synced", body: "zebra", updatedAt: "2020-01-01T00:00:00.000Z" });
    expect(await upsertDocuments(env.DB, "u1", [stale])).toMatchObject({ accepted: 0 });
  });
});
