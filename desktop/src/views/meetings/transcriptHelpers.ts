import type { MeetingRecord, MeetingSegment, MeetingSummary, SummaryPoint } from "../../api/parityTypes";

export interface MeetingTranscriptPassage {
  id: string;
  start: number;
  track: "microphone" | "system";
  text: string;
  segmentIDs: string[];
}

export function formatDuration(seconds: number): string {
  if (isNaN(seconds) || seconds < 0) return "0:00";
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  return `${m}:${s.toString().padStart(2, "0")}`;
}

export function formatTimestamp(seconds: number): string {
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  return `${m.toString().padStart(2, "0")}:${s.toString().padStart(2, "0")}`;
}

export function groupTranscriptPassages(
  segments: MeetingSegment[],
  filterTrack?: "microphone" | "system"
): MeetingTranscriptPassage[] {
  const filtered = segments
    .filter(
      (s) =>
        (!filterTrack || s.track === filterTrack) &&
        s.text.trim().length > 0
    )
    .sort((a, b) => (a.start === b.start ? a.id.localeCompare(b.id) : a.start - b.start));

  const passages: MeetingTranscriptPassage[] = [];
  const ends: Record<string, number> = {};
  const lastByTrack: Record<string, number> = {};

  for (const segment of filtered) {
    const text = segment.text.trim();
    const track = segment.track;
    const lastIndex = lastByTrack[track];
    const prevEnd = ends[track];

    if (
      lastIndex !== undefined &&
      prevEnd !== undefined &&
      segment.start - prevEnd <= 3 &&
      segment.start - passages[lastIndex].start < 90
    ) {
      passages[lastIndex].text += " " + text;
      passages[lastIndex].segmentIDs.push(segment.id);
    } else {
      lastByTrack[track] = passages.length;
      passages.push({
        id: segment.id,
        start: segment.start,
        track: segment.track,
        text,
        segmentIDs: [segment.id]
      });
    }

    ends[track] = segment.start + segment.duration;
  }

  return passages.sort((a, b) =>
    a.start === b.start ? a.id.localeCompare(b.id) : a.start - b.start
  );
}

export interface CitationLink {
  sourceId: string;
  segment?: MeetingSegment;
  passage?: MeetingTranscriptPassage;
  timestamp: string;
}

export function mapCitations(
  sources: string[],
  record: MeetingRecord,
  passages: MeetingTranscriptPassage[]
): CitationLink[] {
  return sources.map((sourceId) => {
    const segment = record.segments.find((s) => s.id === sourceId);
    const passage = passages.find((p) => p.segmentIDs.includes(sourceId));
    const start = segment?.start ?? passage?.start ?? 0;
    return {
      sourceId,
      segment,
      passage,
      timestamp: formatTimestamp(start)
    };
  });
}
