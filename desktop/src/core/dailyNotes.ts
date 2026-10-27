import type { NoteCapture, VoiceNote } from "./model";
export const isDailyNote = (note: VoiceNote) => note.captures != null;
export const visibleCaptures = (note: VoiceNote) => (note.captures ?? []).filter(c => c.superseded !== true);
const join = (texts: string[]) => texts.filter(t => t !== "").join("\n\n");
export function displayText(note: VoiceNote): string {
  if (isDailyNote(note) && note.editedText == null) return note.cleanedText;
  return note.editedText ?? (note.cleanedText === "" ? note.rawText : note.cleanedText);
}
export function displayTitle(note: VoiceNote): string {
  const name = note.title.trim();
  if (name && name !== "Untitled note") return name;
  const words = (displayText(note).split(/[\r\n\v\f\u0085\u2028\u2029]/).find(Boolean) ?? "").trim().split(/\s+/).join(" ");
  const characters = new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(words);
  return words ? Array.from(characters).slice(0, 64).map(c => c.segment).join("") : "Untitled note";
}
export const lastCapturedAt = (note: VoiceNote) => note.captures?.at(-1)?.createdAt ?? note.createdAt;
export const latestCapture = (note: VoiceNote) => [...visibleCaptures(note)].reverse().find(c => c.text !== "");
export const latestText = (note: VoiceNote) => latestCapture(note)?.text ?? displayText(note);
export function pasteLastText(notes: VoiceNote[]): string | undefined {
  const newest = [...notes].sort((a,b) => Date.parse(lastCapturedAt(b)) - Date.parse(lastCapturedAt(a)))[0];
  return newest && latestText(newest);
}
export function recomputeFromCaptures(note: VoiceNote): VoiceNote {
  const entries = note.captures ?? [];
  const one = (values: (string | null | undefined)[]) => {
    const unique = [...new Set(values.filter((v): v is string => v != null))];
    return unique.length === 1 ? unique[0] : undefined;
  };
  return { ...note, rawText: join(entries.filter(c => c.kind !== "text").map(c => c.rawText)),
    cleanedText: join(entries.filter(c => c.superseded !== true).map(c => c.text)),
    duration: entries.reduce((n,c) => n+c.duration, 0), createdAt: entries[0]?.createdAt ?? note.createdAt,
    sourceApplication: one(entries.map(c => c.sourceApplication)), sourceBundleIdentifier: one(entries.map(c => c.sourceBundleIdentifier)) };
}
export function appendCaptures(note: VoiceNote, incoming: NoteCapture[]): VoiceNote {
  const known = new Set((note.captures ?? []).map(c => c.id));
  const added = incoming.filter(c => !known.has(c.id));
  if (!added.length) return note;
  return recomputeFromCaptures({ ...note, editedText: note.editedText == null ? note.editedText : join([note.editedText, ...added.map(c => c.text)]),
    captures: [...(note.captures ?? []), ...added].sort((a,b) => Date.parse(a.createdAt)-Date.parse(b.createdAt)) });
}
export function updateCapture(note: VoiceNote, capture: NoteCapture): VoiceNote {
  if (!note.captures?.some(c => c.id === capture.id)) return note;
  return recomputeFromCaptures({ ...note, captures: note.captures.map(c => c.id === capture.id ? capture : c) });
}
export const removeCapture = (note: VoiceNote, id: string) => recomputeFromCaptures({ ...note, captures: note.captures?.filter(c => c.id !== id) });
export function mergingNewCaptures(note: VoiceNote, stored: VoiceNote): VoiceNote {
  const known = new Set(note.captures?.map(c => c.id));
  const added = (stored.captures ?? []).filter(c => !known.has(c.id));
  const merged = appendCaptures(note, added);
  return note.editedText != null && added.length ? { ...merged, editedText: join([displayText(note), ...added.map(c => c.text)]) } : merged;
}
export function migratedToTimeline(note: VoiceNote, newID: () => string = () => crypto.randomUUID().toUpperCase()): VoiceNote {
  if (!isDailyNote(note) || note.editedText == null) return note;
  const visible = visibleCaptures(note);
  let entries = note.captures ?? [];
  if (note.editedText !== join(visible.map(c => c.text))) {
    entries = entries.map(c => c.superseded !== true && (c.kind == null || c.kind === "dictation" || c.kind === "text") ? { ...c, superseded: true } : c);
    entries = [...entries, { id: newID(), createdAt: visible[0]?.createdAt ?? note.createdAt, title: "", rawText: join(entries.filter(c => c.superseded).map(c => c.rawText || c.text)), text: note.editedText, duration: 0, kind: "text" }];
    entries.sort((a,b) => Date.parse(a.createdAt)-Date.parse(b.createdAt));
  }
  return recomputeFromCaptures({ ...note, editedText: undefined, captures: entries });
}
export function localDay(value: string | Date): string {
  const date = new Date(value);
  return `${date.getFullYear()}-${String(date.getMonth()+1).padStart(2,"0")}-${String(date.getDate()).padStart(2,"0")}`;
}
const dayTitle = (date: string) => new Date(date).toLocaleDateString(undefined, { year: "numeric", month: "long", day: "numeric" });
export function addCapture(notes: VoiceNote[], capture: NoteCapture): VoiceNote[] {
  const existing = notes.find(n => isDailyNote(n) && localDay(n.createdAt) === localDay(capture.createdAt));
  const daily: VoiceNote = existing ?? { id: capture.id, createdAt: capture.createdAt, title: dayTitle(capture.createdAt), rawText: "", cleanedText: "", duration: 0, isPinned: false, tags: [], source: "Dictation", captures: [] };
  return [...notes.filter(n => n !== existing), appendCaptures(daily,[capture])].sort((a,b) => Date.parse(lastCapturedAt(b))-Date.parse(lastCapturedAt(a)));
}
export function groupExistingDictations(notes: VoiceNote[]): VoiceNote[] {
  const grouped = notes.filter(n => n.source !== "Dictation" || isDailyNote(n));
  for (const original of notes.filter(n => n.source === "Dictation" && !isDailyNote(n)).sort((a,b) => Date.parse(a.createdAt)-Date.parse(b.createdAt))) {
    const capture: NoteCapture = { id: original.id, createdAt: original.createdAt, title: original.title, rawText: original.rawText, text: displayText(original), duration: original.duration, sourceApplication: original.sourceApplication, sourceBundleIdentifier: original.sourceBundleIdentifier };
    const index = grouped.findIndex(n => isDailyNote(n) && localDay(n.createdAt) === localDay(original.createdAt));
    if (index >= 0) grouped[index] = { ...appendCaptures(grouped[index],[capture]), isPinned: grouped[index].isPinned || original.isPinned, tags: [...new Set([...grouped[index].tags,...original.tags])].sort() };
    else grouped.push({ ...original, title: dayTitle(original.createdAt), cleanedText: displayText(original), captures: [capture] });
  }
  return grouped.sort((a,b) => Date.parse(lastCapturedAt(b))-Date.parse(lastCapturedAt(a)));
}
