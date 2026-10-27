import type { VoiceNote } from "../../api/parityTypes";
import { visibleCaptures } from "./libraryHelpers";

/** DayNoteExport.markdown in DayNoteView.swift; date and time use the user's locale. */
export function dayMarkdown(note: VoiceNote): string {
  const date = new Date(note.createdAt).toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric", year: "numeric" });
  const lines = [`# ${date}`, ""];
  for (const entry of visibleCaptures(note)) {
    const time = new Date(entry.createdAt).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
    if (entry.kind === "dictation" || entry.kind === "text") {
      if (entry.text) lines.push(`**${time}**`, entry.text, "");
    } else if (entry.kind === "screenshot") lines.push(`**${time}** · Screenshot${entry.attachment ? ` (${entry.attachment})` : ""}`, "");
    else lines.push(`**${time}** · Meeting: ${entry.title}`, "");
  }
  return lines.join("\n").trim();
}
