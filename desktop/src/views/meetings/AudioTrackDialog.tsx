import React, { useEffect, useRef } from "react";
import type { MeetingRecord } from "../../api/parityTypes";
import { MeetingRecordings } from "./MeetingRecordings";

export function AudioTrackDialog({ record, busy, onEdit, onClose }: { record: MeetingRecord; busy: boolean; onEdit: (record: MeetingRecord) => void; onClose: () => void }) {
  const dialog = useRef<HTMLDialogElement>(null);
  useEffect(() => { dialog.current?.showModal(); return () => dialog.current?.close(); }, []);
  return <dialog ref={dialog} aria-modal="true" aria-label="Audio & track names" onCancel={onClose} style={{ width: 620, maxWidth: "90vw", maxHeight: "85vh", overflowY: "auto", border: "1px solid var(--os-line)", borderRadius: 14, background: "var(--os-background)", color: "var(--os-ink)", padding: 24 }}>
    <h2>Audio &amp; track names</h2>
    <p>Track names are used in the transcript and exports.</p>
    {record.includesMicrophone && <p><label>Microphone <input disabled={busy} value={record.microphoneLabel} onChange={event => onEdit({ ...record, microphoneLabel: event.target.value })} /></label></p>}
    {record.includesSystemAudio && <p><label>System audio <input disabled={busy} value={record.systemLabel} onChange={event => onEdit({ ...record, systemLabel: event.target.value })} /></label></p>}
    <MeetingRecordings record={record} />
    <button onClick={onClose}>Done</button>
  </dialog>;
}
