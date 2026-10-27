import { describe, expect, it } from "vitest";
import type { VoiceNote, NoteCapture } from "../../api/parityTypes";
import { editNoteText, noteGroup, noteListing, notePreview, noteText, noteTitle } from "./libraryHelpers";
import { dayMarkdown } from "./dayMarkdown";
const note = (overrides: Partial<VoiceNote> = {}): VoiceNote => ({ id: "A", createdAt: new Date(2026, 9, 22, 9).toISOString(), title: "Untitled note", rawText: "original speech", cleanedText: "Clean speech", duration: 3, isPinned: false, tags: [], source: "Dictation", ...overrides });
const capture = (overrides: Partial<NoteCapture> = {}): NoteCapture => ({ id: "C", createdAt: new Date(2026, 9, 22, 10).toISOString(), title: "Entry", rawText: "raw", text: "Latest entry", kind: "dictation", duration: 2, ...overrides });
const now = new Date(2026, 9, 22, 0, 5);
describe("local notes grouping", () => {
  it("uses calendar days and the seven-day cutoff", () => {
    expect(noteGroup(new Date(2026, 9, 22, 23).toISOString(), now)).toBe("Today");
    expect(noteGroup(new Date(2026, 9, 21, 23).toISOString(), now)).toBe("Yesterday");
    expect(noteGroup(new Date(2026, 9, 16, 23).toISOString(), now)).toBe("Previous 7 days");
    expect(noteGroup(new Date(2026, 9, 15, 23).toISOString(), now)).toBe(new Date(2026, 9, 15).toLocaleDateString(undefined, { month: "long", year: "numeric" }));
  });
  it("pins first, sorts by last capture, excludes today's dedicated row, and paginates 60", () => {
    const records = Array.from({ length: 65 }, (_, i) => note({ id: String(i), createdAt: new Date(2026, 9, 1, i % 24).toISOString() }));
    const pinned = note({ id: "pinned", isPinned: true, createdAt: new Date(2025, 1, 1).toISOString() });
    const latest = note({ id: "latest", captures: [capture()] });
    const result = noteListing([...records, pinned, latest, note({ id: "today" })], { search: "", filter: "all", todayId: "today", limit: 60, now });
    expect(result.total).toBe(67); expect(result.rows).toHaveLength(60);
    expect(result.rows[0].note.id).toBe("pinned"); expect(result.rows[0].group).toBe("Pinned"); expect(result.rows[1].note.id).toBe("latest");
    expect(noteListing(records, { search: "", filter: "all", limit: 120 }).rows).toHaveLength(65);
  });
  it("searches edited text and OCR, includes today when searching, and respects filters", () => {
    const daily = note({ id: "today", captures: [capture({ kind: "screenshot", recognizedText: "Invoice 42" })] });
    expect(noteListing([daily], { search: "invoice", filter: "daily", todayId: "today", limit: 60 }).total).toBe(1);
    expect(noteListing([daily], { search: "invoice", filter: "written", limit: 60 }).total).toBe(0);
    expect(noteListing([note({ editedText: "my correction" })], { search: "correction", filter: "written", limit: 60 }).total).toBe(1);
  });
});
describe("lossless edits and previews", () => {
  it("keeps original text and captures when clearing an edited note", () => {
    const original = note({ captures: [capture({ recognizedText: "OCR", attachment: "image.png", meetingID: "M" })] });
    const edited = editNoteText(original, "");
    expect(noteText(edited)).toBe(""); expect(edited.rawText).toBe(original.rawText); expect(edited.cleanedText).toBe(original.cleanedText);
    expect(edited.captures).toBe(original.captures); expect(original.editedText).toBeUndefined();
  });
  it("never resurrects raw text in a cleared daily note", () => { expect(noteText(note({ captures: [], cleanedText: "" }))).toBe(""); });
  it("previews the latest visible nonempty capture and clips it", () => {
    expect(notePreview(note({ captures: [capture({ text: "a".repeat(300) }), capture({ text: "" }), capture({ superseded: true, text: "hidden" })] }))).toHaveLength(280);
  });
  it("derives untitled titles from the edited first line", () => { expect(noteTitle(note({ editedText: "  New   title\nBody" }))).toBe("New title"); });
});
it("exports Swift daily Markdown with visible text, attachment names and meeting references", () => {
  const result = dayMarkdown(note({ captures: [capture(), capture({ id: "S", kind: "screenshot", attachment: "Screenshot-X.png", recognizedText: "OCR not in export" }), capture({ id: "M", kind: "meeting", title: "Planning" }), capture({ id: "H", superseded: true, text: "hidden" }), capture({ id: "E", text: "" })] }));
  expect(result).toContain("Latest entry"); expect(result).toContain("Screenshot (Screenshot-X.png)"); expect(result).toContain("Meeting: Planning");
  expect(result).not.toContain("hidden"); expect(result).not.toContain("OCR not in export"); expect(result.endsWith("\n")).toBe(false);
});
