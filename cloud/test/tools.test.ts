import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { upsertDocuments } from "../src/documents";
import {
  buildFtsQuery,
  fetchDocument,
  getMeeting,
  listActionItems,
  listRecent,
  search,
  TRANSCRIPT_CHAR_LIMIT,
} from "../src/tools";
import { daysAgo, makeDoc, resetDb, seedUser } from "./helpers";

const A = "user-a";
const B = "user-b";

beforeEach(async () => {
  await resetDb(env.DB);
  await seedUser(env.DB, A);
  await seedUser(env.DB, B);
  await upsertDocuments(env.DB, A, [
    makeDoc({ id: "a-title", title: "Roadmap review", body: "Went through Q3 goals.", updatedAt: daysAgo(1), createdAt: daysAgo(1) }),
    makeDoc({ id: "a-body", title: "Groceries", body: "Pick up roadmap poster from the printer.", updatedAt: daysAgo(2), createdAt: daysAgo(2) }),
    makeDoc({
      id: "a-meeting",
      kind: "meeting",
      title: "Design sync",
      body: "Remember to share the Figma file.",
      summary: "**Overview**\n- Agreed on the new onboarding flow.",
      transcript: "[00:00] Alice: Let's talk about onboarding.\n[00:12] Bob: The roadmap slipped a week.",
      actionItems: ["Alice: send onboarding mocks", "Bob: update roadmap dates"],
      durationSeconds: 1830,
      tags: ["design"],
      createdAt: daysAgo(3),
      updatedAt: daysAgo(3),
    }),
    makeDoc({
      id: "a-old-meeting",
      kind: "meeting",
      title: "Kickoff",
      actionItems: ["Book venue"],
      createdAt: daysAgo(40),
      updatedAt: daysAgo(40),
    }),
    makeDoc({ id: "a-deleted", title: "Secret roadmap", body: "roadmap roadmap roadmap", deleted: true, updatedAt: daysAgo(1) }),
  ]);
  await upsertDocuments(env.DB, B, [
    makeDoc({ id: "b-1", title: "Roadmap for user B", body: "B's private roadmap", updatedAt: daysAgo(1) }),
    makeDoc({ id: "b-meeting", kind: "meeting", title: "B standup", actionItems: ["B: private task"], createdAt: daysAgo(1), updatedAt: daysAgo(1) }),
  ]);
});

describe("buildFtsQuery", () => {
  it("quotes terms and strips FTS syntax", () => {
    expect(buildFtsQuery('roadmap" OR body:*  NEAR(', "and")).toBe('"roadmap"* "OR"* "body"* "NEAR"*');
    expect(buildFtsQuery("a b", "or")).toBe('"a"* OR "b"*');
    expect(buildFtsQuery("  ** ", "and")).toBeNull();
  });
});

describe("search", () => {
  it("ranks title matches above body matches and above transcript matches", async () => {
    const { structured, text } = await search(env.DB, A, { query: "roadmap" });
    expect(structured.results.map((r) => r.id)).toEqual(["a-title", "a-body", "a-meeting"]);
    expect(structured.results[1]!.snippet).toContain("**roadmap**");
    expect(JSON.parse(text)).toEqual({ results: structured.results });
    expect(Object.keys(structured.results[0]!).sort()).toEqual(["createdAt", "id", "kind", "snippet", "title"]);
  });

  it("never returns another user's documents", async () => {
    const a = await search(env.DB, A, { query: "roadmap private" });
    expect(a.structured.results.every((r) => r.id.startsWith("a-"))).toBe(true);
    const b = await search(env.DB, B, { query: "roadmap" });
    expect(b.structured.results.map((r) => r.id)).toEqual(["b-1"]);
    expect((await search(env.DB, B, { query: "onboarding" })).structured.results).toEqual([]);
  });

  it("filters by kind, honors limit, excludes tombstones, falls back to OR", async () => {
    expect((await search(env.DB, A, { query: "roadmap", kind: "meeting" })).structured.results.map((r) => r.id)).toEqual(["a-meeting"]);
    expect((await search(env.DB, A, { query: "roadmap", limit: 1 })).structured.results).toHaveLength(1);
    expect((await search(env.DB, A, { query: "secret" })).structured.results).toEqual([]);
    // No document has both words, so the OR fallback finds both.
    const ids = (await search(env.DB, A, { query: "groceries figma" })).structured.results.map((r) => r.id).sort();
    expect(ids).toEqual(["a-body", "a-meeting"]);
    // Prefix matching.
    expect((await search(env.DB, A, { query: "onboard" })).structured.results.map((r) => r.id)).toEqual(["a-meeting"]);
  });
});

describe("fetch", () => {
  it("returns markdown plus the normalized document", async () => {
    const { text, structured } = await fetchDocument(env.DB, A, { id: "a-meeting" });
    expect(text).toContain("# Design sync");
    expect(text).toContain("## Summary");
    expect(text).toContain("- [ ] Alice: send onboarding mocks");
    expect(text).toContain("## Transcript");
    expect(structured).toMatchObject({ id: "a-meeting", kind: "meeting", deleted: false, durationSeconds: 1830, tags: ["design"] });
  });

  it("refuses other users' and deleted documents", async () => {
    await expect(fetchDocument(env.DB, B, { id: "a-meeting" })).rejects.toThrow(/No document/);
    await expect(fetchDocument(env.DB, A, { id: "a-deleted" })).rejects.toThrow(/No document/);
  });

  it("truncates long transcripts with a note", async () => {
    await upsertDocuments(env.DB, A, [makeDoc({ id: "long", kind: "meeting", transcript: "x".repeat(TRANSCRIPT_CHAR_LIMIT + 500) })]);
    const { structured, text } = await fetchDocument(env.DB, A, { id: "long" });
    expect(structured.transcript!.length).toBeLessThan(TRANSCRIPT_CHAR_LIMIT + 400);
    expect(structured.transcript).toContain("Call get_meeting");
    expect(text).toContain("Transcript truncated");
  });
});

describe("list_recent", () => {
  it("lists newest first within the window, without transcripts", async () => {
    const { structured } = await listRecent(env.DB, A, {});
    expect(structured.documents.map((d) => d.id)).toEqual(["a-title", "a-body", "a-meeting"]);
    expect(structured.documents.every((d) => !("transcript" in d))).toBe(true);
    expect((await listRecent(env.DB, A, { kind: "meeting", days: 60 })).structured.documents.map((d) => d.id)).toEqual(["a-meeting", "a-old-meeting"]);
    expect((await listRecent(env.DB, A, { limit: 1 })).structured.documents).toHaveLength(1);
    expect((await listRecent(env.DB, B, {})).structured.documents.map((d) => d.id).sort()).toEqual(["b-1", "b-meeting"]);
  });
});

describe("get_meeting", () => {
  it("returns meeting details and the transcript only on request", async () => {
    const without = await getMeeting(env.DB, A, { id: "a-meeting" });
    expect(without.structured).toMatchObject({ title: "Design sync", durationSeconds: 1830, notes: "Remember to share the Figma file." });
    expect(without.structured).not.toHaveProperty("transcript");
    expect(without.text).not.toContain("## Transcript");
    const withT = await getMeeting(env.DB, A, { id: "a-meeting", includeTranscript: true });
    expect(withT.structured.transcript).toContain("[00:12] Bob");
    expect(withT.text).toContain("## Transcript");
  });

  it("rejects notes and other users' meetings", async () => {
    await expect(getMeeting(env.DB, A, { id: "a-title" })).rejects.toThrow(/No meeting/);
    await expect(getMeeting(env.DB, B, { id: "a-meeting" })).rejects.toThrow(/No meeting/);
  });
});

describe("list_action_items", () => {
  it("flattens action items from recent meetings for the user only", async () => {
    const { structured } = await listActionItems(env.DB, A, {});
    expect(structured.actionItems).toEqual([
      { text: "Alice: send onboarding mocks", meetingId: "a-meeting", meetingTitle: "Design sync", meetingDate: expect.any(String) },
      { text: "Bob: update roadmap dates", meetingId: "a-meeting", meetingTitle: "Design sync", meetingDate: expect.any(String) },
    ]);
    expect((await listActionItems(env.DB, A, { days: 60 })).structured.actionItems.map((a) => a.text)).toContain("Book venue");
    expect((await listActionItems(env.DB, B, {})).structured.actionItems.map((a) => a.text)).toEqual(["B: private task"]);
  });
});
