import type { NoteCapture, VoiceNote } from "../../api/parityTypes";
import { localDay } from "../../core/dailyNotes";

export const isSyntheticDayId = (id: string): boolean => id === "today-placeholder" || id.startsWith("day:");

/** Navigation may address a calendar day before it has any persisted captures. */
export function selectedDayNote(notes: VoiceNote[], selectedId?: string): VoiceNote | undefined {
  const match = /^day:(\d{4})-(\d{2})-(\d{2})$/.exec(selectedId ?? "");
  if (!match) return undefined;
  const [, year, month, day] = match;
  // Numeric local construction avoids interpreting a date-only string as UTC.
  const date = new Date(0);
  date.setFullYear(Number(year), Number(month) - 1, Number(day));
  date.setHours(12, 0, 0, 0);
  if (date.getFullYear() !== Number(year) || date.getMonth() !== Number(month) - 1 || date.getDate() !== Number(day)) return undefined;
  const existing = notes.find(note => note.captures != null && localDay(note.createdAt) === localDay(date));
  return existing ?? {
    id: selectedId!,
    createdAt: date.toISOString().replace(/\.\d{3}Z$/, "Z"),
    title: date.toLocaleDateString(undefined, { year: "numeric", month: "long", day: "numeric" }),
    rawText: "", cleanedText: "", duration: 0, isPinned: false, tags: [], source: "Dictation", captures: []
  };
}

/** Edit only visible text, using the latest capture so concurrent OCR metadata survives. */
export const editCaptureText = (capture: NoteCapture, text: string): NoteCapture => ({ ...capture, text });

/** Keep the selected local calendar day when writing to an older daily note. */
export function captureDateForDay(day: string, now = new Date()): string {
  const selected = new Date(day);
  const date = new Date(now);
  date.setFullYear(selected.getFullYear(), selected.getMonth(), selected.getDate());
  return date.toISOString().replace(/\.\d{3}Z$/, "Z");
}
