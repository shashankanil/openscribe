import { describe, expect, it } from "vitest";
import type { MeetingRecord, MeetingSegment } from "../../api/parityTypes";
import {
  formatDuration,
  formatTimestamp,
  groupTranscriptPassages,
  mapCitations
} from "./transcriptHelpers";

describe("Transcript helpers and passage grouping", () => {
  it("formats durations and timestamps", () => {
    expect(formatDuration(0)).toBe("0:00");
    expect(formatDuration(65)).toBe("1:05");
    expect(formatDuration(3605)).toBe("60:05");
    expect(formatTimestamp(15)).toBe("00:15");
    expect(formatTimestamp(125)).toBe("02:05");
  });

  it("groups contiguous segments of the same track into a single passage", () => {
    const segments: MeetingSegment[] = [
      {
        id: "part1/microphone/chunk-00000.wav",
        track: "microphone",
        start: 0,
        duration: 15,
        text: "Hello everyone,"
      },
      {
        id: "part1/microphone/chunk-00001.wav",
        track: "microphone",
        start: 15,
        duration: 15,
        text: "welcome to the meeting."
      },
      {
        id: "part1/system/chunk-00000.wav",
        track: "system",
        start: 16,
        duration: 10,
        text: "Thanks for hosting."
      }
    ];

    const passages = groupTranscriptPassages(segments);
    // Should have 2 passages: microphone (combined chunk 0 and 1) and system
    expect(passages.length).toBe(2);

    const micPassage = passages.find((p) => p.track === "microphone");
    expect(micPassage).toBeDefined();
    expect(micPassage?.text).toBe("Hello everyone, welcome to the meeting.");
    expect(micPassage?.segmentIDs).toEqual([
      "part1/microphone/chunk-00000.wav",
      "part1/microphone/chunk-00001.wav"
    ]);

    const sysPassage = passages.find((p) => p.track === "system");
    expect(sysPassage).toBeDefined();
    expect(sysPassage?.text).toBe("Thanks for hosting.");
  });

  it("splits passages when gap between segments exceeds 3 seconds", () => {
    const segments: MeetingSegment[] = [
      {
        id: "part1/microphone/chunk-00000.wav",
        track: "microphone",
        start: 0,
        duration: 15,
        text: "First thought."
      },
      {
        id: "part1/microphone/chunk-00001.wav",
        track: "microphone",
        start: 25, // 25 - 15 = 10s gap > 3s
        duration: 15,
        text: "Second thought after silence."
      }
    ];

    const passages = groupTranscriptPassages(segments);
    expect(passages.length).toBe(2);
    expect(passages[0].text).toBe("First thought.");
    expect(passages[1].text).toBe("Second thought after silence.");
  });

  it("maps summary source citations to segments and passages", () => {
    const segments: MeetingSegment[] = [
      {
        id: "mic-1",
        track: "microphone",
        start: 30,
        duration: 15,
        text: "We decided to launch on Friday."
      }
    ];
    const dummyRecord: MeetingRecord = {
      id: "REC-1",
      title: "Launch Sync",
      createdAt: 1000,
      duration: 45,
      status: "ready",
      summarizeOnStop: true,
      includesMicrophone: true,
      includesSystemAudio: false,
      settings: {},
      segments,
      summary: null,
      microphoneLabel: "Microphone",
      systemLabel: "System audio"
    };

    const passages = groupTranscriptPassages(segments);
    const citations = mapCitations(["mic-1"], dummyRecord, passages);

    expect(citations.length).toBe(1);
    expect(citations[0].sourceId).toBe("mic-1");
    expect(citations[0].timestamp).toBe("00:30");
    expect(citations[0].segment?.text).toBe("We decided to launch on Friday.");
    expect(citations[0].passage?.text).toBe("We decided to launch on Friday.");
  });
});
