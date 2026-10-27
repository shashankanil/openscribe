import type { VoiceNote } from "../../api/parityTypes";
import { localDay, displayText, displayTitle } from "../../core/dailyNotes";

export const noteText = (note: VoiceNote): string => displayText(note);
export const visibleCaptures = (note: VoiceNote) => (note.captures ?? []).filter(c => !c.superseded);
export function noteTitle(note: VoiceNote): string {
  return displayTitle(note);
}
export function notePreview(note: VoiceNote): string {
  return (note.captures != null ? visibleCaptures(note).filter(c => c.text).at(-1)?.text ?? noteText(note) : noteText(note)).slice(0, 280);
}
export function noteGroup(date: string, now = new Date()): string {
  const day = new Date(date);
  const yesterday = new Date(now); yesterday.setDate(now.getDate() - 1);
  if (localDay(day) === localDay(now)) return "Today";
  if (localDay(day) === localDay(yesterday)) return "Yesterday";
  // Calendar-day distance, independent of DST's 23/25-hour days.
  const serial = (d: Date) => Date.UTC(d.getFullYear(), d.getMonth(), d.getDate());
  if ((serial(now) - serial(day)) / 86400000 < 7) return "Previous 7 days";
  return day.toLocaleDateString(undefined, { month: "long", year: "numeric" });
}
export function noteListing(notes: VoiceNote[], options: { search: string; filter: "all" | "daily" | "written"; todayId?: string; limit: number; now?: Date }) {
  const q = options.search.trim().toLocaleLowerCase();
  const filtered = notes.filter(n => {
    if (options.filter === "daily" && n.captures == null || options.filter === "written" && n.captures != null) return false;
    if (!q) return n.id !== options.todayId;
    return [n.title, noteText(n), ...(n.captures ?? []).flatMap(c => [c.text, c.rawText, c.recognizedText ?? ""])].some(t => t.toLocaleLowerCase().includes(q));
  });
  const lastDate = (n: VoiceNote) => new Date(n.captures?.at(-1)?.createdAt ?? n.createdAt).getTime();
  filtered.sort((a, b) => Number(b.isPinned) - Number(a.isPinned) || lastDate(b) - lastDate(a));
  return { total: filtered.length, rows: filtered.slice(0, options.limit).map(note => ({ note, group: note.isPinned ? "Pinned" : noteGroup(note.captures?.at(-1)?.createdAt ?? note.createdAt, options.now) })) };
}
/** Written edits preserve original dictation and all capture metadata, including an intentional empty edit. */
export const editNoteText = (note: VoiceNote, text: string): VoiceNote => ({ ...note, editedText: text });
