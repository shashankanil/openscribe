import React, { useEffect, useRef, useState } from "react";
import { updateCapture } from "../../api/parity";
import type { NoteCapture } from "../../api/parityTypes";
import { reportUiError } from "../../workspaceEvents";
import { editCaptureText } from "./dayNoteHelpers";

export function EntryTextEditor({ entry, noteId, onRefresh }: { entry: NoteCapture; noteId: string; onRefresh: () => Promise<void> }) {
  const [text, setText] = useState(entry.text);
  const [editing, setEditing] = useState(false);
  const [status, setStatus] = useState("");
  const latest = useRef(entry); latest.current = entry;
  const draft = useRef(text); draft.current = text;
  const saved = useRef(entry.text);
  const queue = useRef<Promise<unknown>>(Promise.resolve());
  const refresh = useRef(onRefresh); refresh.current = onRefresh;
  const save = () => {
    const value = draft.current;
    queue.current = queue.current.catch(() => undefined).then(async () => {
      if (saved.current === value) return;
      setStatus("Saving…");
      await updateCapture(editCaptureText(latest.current, value), noteId);
      saved.current = value; await refresh.current(); setStatus("Saved");
    }).catch(error => { setStatus("Could not save. Your draft is kept here."); setEditing(true); reportUiError(error); });
  };
  useEffect(() => { if (!editing && saved.current === draft.current) { saved.current = entry.text; setText(entry.text); } }, [entry.text, editing]);
  useEffect(() => {
    if (!editing || text === saved.current) return;
    setStatus("Unsaved changes"); const timer = setTimeout(save, 450); return () => clearTimeout(timer);
  }, [text, editing]);
  useEffect(() => () => { if (draft.current !== saved.current) save(); }, []);
  return <div>
    {editing ? <textarea autoFocus aria-label="Entry text" value={text} onChange={event => setText(event.target.value)} onBlur={() => { save(); }} style={{ width: "100%", minHeight: 80, resize: "vertical", border: 0, background: "transparent", color: "var(--os-ink)", font: "inherit", lineHeight: 1.6 }} /> : <button onClick={() => setEditing(true)} aria-label="Edit entry text" style={{ whiteSpace: "pre-wrap", textAlign: "left", width: "100%", border: 0, padding: 0, background: "transparent", color: "var(--os-ink)", font: "inherit", lineHeight: 1.6 }}>{text || "Empty"}</button>}
    {editing && <div><small role="status">{status}</small> <button onClick={save}>Save</button> <button onClick={() => { save(); setEditing(false); }}>Done</button></div>}
  </div>;
}
