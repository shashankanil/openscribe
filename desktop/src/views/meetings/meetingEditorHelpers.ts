import type { MeetingRecord } from "../../api/parityTypes";
/** Local metadata drafts must never freeze a recording's changing transcript or status. */
export function withMeetingDraft(current: MeetingRecord, draft?: MeetingRecord): MeetingRecord {
  return draft ? { ...current, title: draft.title, userNotes: draft.userNotes, microphoneLabel: draft.microphoneLabel, systemLabel: draft.systemLabel } : current;
}
