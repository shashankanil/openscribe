import { expect, it } from "vitest";
import type { MeetingRecord } from "../../api/parityTypes";
import { withMeetingDraft } from "./meetingEditorHelpers";
it("keeps new live chunks/status while metadata edits are pending", () => {
  const draft = { id: "M", title: "Draft title", userNotes: "My notes", microphoneLabel: "Me", systemLabel: "Guests", status: "recording", segments: [], summary: null } as unknown as MeetingRecord;
  const current = { ...draft, title: "Stored title", status: "paused" as const, segments: [{ id: "new.wav", text: "New speech", start: 0, duration: 15, track: "system" as const }], lastError: "Live failed" };
  const result = withMeetingDraft(current, draft);
  expect(result.title).toBe("Draft title"); expect(result.userNotes).toBe("My notes"); expect(result.microphoneLabel).toBe("Me");
  expect(result.segments).toBe(current.segments); expect(result.status).toBe("paused"); expect(result.lastError).toBe("Live failed"); expect(withMeetingDraft(current)).toBe(current);
});
