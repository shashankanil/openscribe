import React, { useEffect, useRef, useState } from "react";
import { convertFileSrc } from "@tauri-apps/api/core";
import { meetingAudioPath } from "../../api/parity";
import type { MeetingRecord } from "../../api/parityTypes";

export function SegmentAudio({ record, segmentId }: { record: MeetingRecord; segmentId: string }) {
  const [source, setSource] = useState("");
  const [error, setError] = useState("");
  useEffect(() => {
    let disposed = false; setSource(""); setError("");
    const segment = record.segments.find(segment => segment.id === segmentId);
    if (!segment || segment.duration <= 0 || !segment.id.endsWith(".wav")) { setError("No saved audio is available for this passage."); return; }
    void meetingAudioPath(record.id, segmentId).then(path => { if (!disposed) setSource(convertFileSrc(path)); }).catch(error => { if (!disposed) setError(String(error)); });
    return () => { disposed = true; };
  }, [record.id, segmentId]);
  return <div>{error ? <p role="alert">{error}</p> : source ? <audio key={source} controls autoPlay src={source} aria-label="Passage audio" onError={() => setError("This audio chunk could not be played.")} /> : <p role="status">Loading saved audio…</p>}</div>;
}
