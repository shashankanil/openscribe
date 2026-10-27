import React, { useEffect, useState } from "react";
import { listMeetings, parityEvents } from "../../api/parity";
import type { MeetingRecord, NoteCapture } from "../../api/parityTypes";
import { reportUiError } from "../../workspaceEvents";
import { formatDuration } from "../meetings/transcriptHelpers";

export function MeetingEntryCard({ entry, onOpen }: { entry: NoteCapture; onOpen?: (id: string) => void }) {
  const [record, setRecord] = useState<MeetingRecord | null>(null);
  const [error, setError] = useState("");
  useEffect(() => {
    let disposed = false;
    const subscription = parityEvents.onMeetingChanged(value => { if (!disposed && value.id === entry.meetingID) setRecord(value); });
    void subscription.catch(error => { if (!disposed) setError(String(error)); });
    void listMeetings().then(records => { if (!disposed) setRecord(records.find(value => value.id === entry.meetingID) ?? null); }).catch(error => { if (!disposed) setError(String(error)); });
    return () => { disposed = true; void subscription.then(unlisten => unlisten()).catch(reportUiError); };
  }, [entry.meetingID]);
  const active = record?.status === "recording" || record?.status === "paused";
  return <div style={{ border: "1px solid var(--os-line)", borderRadius: 10, padding: 12 }}>
    <button disabled={!entry.meetingID || !onOpen} onClick={() => onOpen?.(entry.meetingID!)} style={{ border: 0, padding: 0, width: "100%", textAlign: "left", background: "transparent", color: "var(--os-ink)" }}>
      <strong>{record?.title || entry.title || "Meeting"}</strong> <span style={{ color: "var(--os-ink-muted)" }}>{record?.status ?? "Meeting unavailable"}</span>
      <p>{record?.summary?.overview[0]?.text || record?.userNotes || ""}</p>
      {!!record?.summary?.actions.length && <p>{record.summary.actions.length} action item{record.summary.actions.length === 1 ? "" : "s"}</p>}
      <small>{active ? "Open meeting notes" : formatDuration(record?.duration ?? entry.duration)}</small>
    </button>
    {error && <p role="alert">{error}</p>}
  </div>;
}
