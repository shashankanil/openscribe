import { describe, expect, it } from "vitest";
import { captureDateForDay, editCaptureText, isSyntheticDayId, selectedDayNote } from "./dayNoteHelpers";
import type { NoteCapture } from "../../api/parityTypes";

it("clears visible capture text while retaining original speech and concurrent metadata", () => {
  const capture: NoteCapture = { id: "C", createdAt: "2026-10-22T01:00:00Z", title: "Capture", rawText: "original speech", text: "edited speech", duration: 4, kind: "dictation", attachment: "Screenshot-X.png", recognizedText: "new OCR", meetingID: "M", sourceApplication: "app.exe" };
  const edited = editCaptureText(capture, "");
  expect(edited).toEqual({ ...capture, text: "" });
  expect(capture.text).toBe("edited speech");
});

describe("captureDateForDay", () => {
  it("adds a thought to the selected local day rather than today", () => {
    const day = new Date(2024, 1, 29, 8);
    const now = new Date(2026, 9, 20, 15, 42, 3, 500);
    const result = new Date(captureDateForDay(day.toISOString(), now));
    expect([result.getFullYear(), result.getMonth(), result.getDate()]).toEqual([2024, 1, 29]);
    expect([result.getHours(), result.getMinutes(), result.getSeconds(), result.getMilliseconds()]).toEqual([15, 42, 3, 0]);
    expect(now.getFullYear()).toBe(2026);
  });

  it("keeps today's local day across UTC date boundaries", () => {
    const now = new Date(2026, 9, 20, 0, 5);
    const result = new Date(captureDateForDay(now.toISOString(), now));
    expect(result.toDateString()).toBe(now.toDateString());
  });
});

describe("historical day navigation", () => {
  it("creates an empty daily placeholder at local noon, without treating the day as UTC", () => {
    const note = selectedDayNote([], "day:2024-02-29")!;
    const date = new Date(note.createdAt);
    expect(note.id).toBe("day:2024-02-29"); expect(note.captures).toEqual([]);
    expect([date.getFullYear(), date.getMonth(), date.getDate(), date.getHours(), date.getMinutes()]).toEqual([2024, 1, 29, 12, 0]);
    expect(note.createdAt).toMatch(/T\d{2}:\d{2}:\d{2}Z$/);
    expect(note.isPinned).toBe(false);
  });

  it("routes a thought to the historical day and adopts the real daily note after refresh", () => {
    const placeholder = selectedDayNote([], "day:2024-02-29")!;
    const captureDate = captureDateForDay(placeholder.createdAt, new Date(2026, 9, 22, 0, 5));
    const date = new Date(captureDate);
    expect([date.getFullYear(), date.getMonth(), date.getDate(), date.getHours()]).toEqual([2024, 1, 29, 0]);
    const written = { ...placeholder, id: "WRITTEN", captures: undefined };
    const saved = { ...placeholder, id: "PERSISTED", createdAt: captureDate };
    expect(selectedDayNote([written, saved], placeholder.id)).toBe(saved);
    expect(isSyntheticDayId(saved.id)).toBe(false);
  });

  it("rejects malformed and impossible dates instead of rolling into another local day", () => {
    for (const id of ["day:2023-02-29", "day:2024-13-01", "day:2024-04-31", "day:2024-00-01", "day:2024-01-00", "day:2024-2-9", "day:2024-02-29extra", "SAVED-ID"]) {
      expect(selectedDayNote([], id)).toBeUndefined();
    }
  });

  it("identifies both historical and today placeholders as synthetic", () => {
    expect(isSyntheticDayId("today-placeholder")).toBe(true);
    expect(isSyntheticDayId("day:2024-02-29")).toBe(true);
    expect(isSyntheticDayId("SAVED-ID")).toBe(false);
  });
});
