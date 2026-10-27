import React, { useEffect, useRef, useState } from "react";
import { convertFileSrc, invoke } from "@tauri-apps/api/core";
import { meetingAudioPath } from "../../api/parity";
import type { MeetingRecord, MeetingSegment } from "../../api/parityTypes";
import { formatDuration, formatTimestamp } from "./transcriptHelpers";

export function MeetingRecordings({ record }: { record: MeetingRecord }) {
  const [sources, setSources] = useState<Record<string, string>>({});
  const [error, setError] = useState("");
  const [inventory, setInventory] = useState<{ id: string; chunks: MeetingSegment[] } | null>(null);
  const [inventoryError, setInventoryError] = useState("");
  const [loading, setLoading] = useState(false);
  const [retry, setRetry] = useState(0);
  const currentMeeting = useRef(record.id); currentMeeting.current = record.id;
  const playable = (inventory?.id === record.id ? inventory.chunks : record.segments)
    .filter(segment => segment.duration > 0 && segment.id.endsWith(".wav"))
    .slice().sort((a, b) => a.start - b.start || a.id.localeCompare(b.id));
  useEffect(() => { setError(""); setSources({}); }, [record.id]);
  useEffect(() => {
    let disposed = false;
    setLoading(true); setInventoryError("");
    void invoke<MeetingSegment[]>("list_meeting_audio_chunks", { id: record.id }).then(chunks => {
      if (!disposed) setInventory({ id: record.id, chunks });
    }).catch(error => {
      if (!disposed) { setInventory(null); setInventoryError(String(error)); }
    }).finally(() => { if (!disposed) setLoading(false); });
    return () => { disposed = true; };
  }, [record.id, record.status, record.segments, retry]);
  const open = async (id: string) => {
    setError("");
    try {
      const path = await meetingAudioPath(record.id, id);
      if (currentMeeting.current === record.id) setSources(current => ({ ...current, [`${record.id}/${id}`]: convertFileSrc(path) }));
    } catch (error) { if (currentMeeting.current === record.id) setError(String(error)); }
  };
  return <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
    {error && <p role="alert" style={{ color: "var(--os-ink)", background: "var(--os-recording-soft)", padding: 12 }}>{error}</p>}
    {loading && <p role="status">Refreshing saved audio…</p>}
    {inventoryError && <div role="alert"><p>Could not list saved audio: {inventoryError}</p><p>Only audio referenced by the transcript is shown.</p><button onClick={() => setRetry(value => value + 1)}>Retry saved audio</button></div>}
    {!loading && !playable.length && <p style={{ color: "var(--os-ink-muted)" }}>{inventoryError ? "No playable transcript audio is available. Other saved audio could not be checked." : "No finalized audio chunks are available yet. Recording files stay on this device."}</p>}
    {playable.map(segment => <div key={segment.id}>
      <span>{segment.track === "microphone" ? record.microphoneLabel : record.systemLabel} · {formatTimestamp(segment.start)} · {formatDuration(segment.duration)} </span>
      {sources[`${record.id}/${segment.id}`] ? <audio controls aria-label={`Audio at ${formatTimestamp(segment.start)}`} src={sources[`${record.id}/${segment.id}`]} onError={() => setError("This audio chunk could not be played.")} /> : <button className="quiet" onClick={() => { void open(segment.id); }}>Load audio</button>}
    </div>)}
  </div>;
}
