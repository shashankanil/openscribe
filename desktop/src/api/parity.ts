import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import type { CalendarPrompt, CalendarDecision } from "../core/calendarPolicy";
import type {
  CalendarEvent,
  MeetingRecord,
  NoteCapture,
  ParitySettings,
  ProfileLoadResult,
  ShortcutBinding,
  VoiceNote
} from "./parityTypes";

// ==========================================
// Storage and Notes Commands (Codex-A)
// ==========================================

export async function loadProfile(): Promise<ProfileLoadResult> {
  return invoke<ProfileLoadResult>("load_profile");
}

export async function saveSettings(settings: ParitySettings): Promise<void> {
  return invoke<void>("save_settings", { settings });
}

export async function saveNote(note: VoiceNote): Promise<void> {
  return invoke<void>("save_note", { note });
}

export async function deleteNote(id: string): Promise<void> {
  return invoke<void>("delete_note", { id });
}

export async function addCapture(capture: NoteCapture): Promise<VoiceNote> {
  return invoke<VoiceNote>("add_capture", { capture });
}

export async function updateCapture(capture: NoteCapture, noteId: string): Promise<void> {
  return invoke<void>("update_capture", { capture, noteId });
}

export async function removeCapture(captureId: string, noteId: string): Promise<void> {
  return invoke<void>("remove_capture", { captureId, noteId });
}

export async function attachmentPath(name: string): Promise<string> {
  return invoke<string>("attachment_path", { name });
}

// ==========================================
// Meetings Commands (Codex-A)
// ==========================================

export interface StartMeetingOptions {
  title: string;
  microphone: boolean;
  systemAudio: boolean;
  summarizeOnStop: boolean;
  liveTranscription: boolean;
}

export async function listMeetings(): Promise<MeetingRecord[]> {
  return invoke<MeetingRecord[]>("list_meetings");
}

export async function startMeeting(options: StartMeetingOptions): Promise<MeetingRecord> {
  return invoke<MeetingRecord>("start_meeting", { ...options });
}

export async function pauseMeeting(): Promise<void> {
  return invoke<void>("pause_meeting");
}

export async function resumeMeeting(): Promise<void> {
  return invoke<void>("resume_meeting");
}

export async function finishMeeting(options?: { summarize?: boolean }): Promise<void> {
  return invoke<void>("finish_meeting", options ?? {});
}

export async function processMeeting(id: string): Promise<void> {
  return invoke<void>("process_meeting", { id });
}

export async function summarizeShortMeeting(id: string): Promise<void> {
  return invoke<void>("summarize_short_meeting", { id });
}

export async function skipSummary(id: string): Promise<void> {
  return invoke<void>("skip_summary", { id });
}

export async function retryLiveTranscription(): Promise<void> {
  return invoke<void>("retry_live_transcription");
}

export async function cancelProcessing(): Promise<void> {
  return invoke<void>("cancel_processing");
}

export async function updateMeeting(record: MeetingRecord): Promise<void> {
  return invoke<void>("update_meeting", { record });
}

export async function deleteMeeting(id: string): Promise<void> {
  return invoke<void>("delete_meeting", { id });
}

export async function exportMeetingMarkdown(id: string): Promise<string> {
  return invoke<string>("export_meeting_markdown", { id });
}

export async function meetingAudioPath(id: string, segmentId: string): Promise<string> {
  return invoke<string>("meeting_audio_path", { id, segmentId });
}

// ==========================================
// Dictionary, Shortcuts, Calendar Commands (Codex-B)
// ==========================================

export interface DictionaryResult {
  text: string;
  learnedWords: string[];
}

export async function applyDictionary(
  text: string,
  settings: ParitySettings
): Promise<DictionaryResult> {
  return invoke<DictionaryResult>("apply_dictionary", { text, settings });
}

/** Resolves to the actions whose keys another app already holds; the others are active. */
export async function registerShortcuts(
  bindings: Record<string, ShortcutBinding>
): Promise<string[]> {
  return (await invoke<string[] | null>("register_shortcuts", { bindings })) ?? [];
}

export async function suspendShortcuts(suspended: boolean): Promise<string[]> {
  return (await invoke<string[] | null>("suspend_shortcuts", { suspended })) ?? [];
}

/** Escape cancels dictation from any app, and is claimed only while recording. */
export async function setEscapeActive(active: boolean): Promise<void> {
  return invoke<void>("set_escape_active", { active });
}

export async function calendarRefresh(): Promise<CalendarEvent[]> {
  return invoke<CalendarEvent[]>("calendar_refresh");
}

export type { CalendarDecision } from "../core/calendarPolicy";

export async function calendarDecision(
  occurrenceId: string,
  decision: CalendarDecision
): Promise<void> {
  return invoke<void>("calendar_decision", { occurrenceId, decision });
}

// ==========================================
// Screenshots Command (Grok)
// ==========================================

export async function takeScreenshot(
  kind: "area" | "window" | "screen"
): Promise<NoteCapture | null> {
  return invoke<NoteCapture | null>("take_screenshot", { kind });
}

// ==========================================
// Event Payloads & Listeners
// ==========================================

export interface MeetingProgressEvent {
  id: string;
  message: string;
}

export interface LevelEvent {
  level: number;
}

export interface ShortcutActionEvent {
  action: string;
  /** "cancelled": Right Ctrl was combined with another key, so it was not meant for dictation. */
  state: "pressed" | "released" | "cancelled";
}

export type CalendarPromptStartEvent = CalendarPrompt;
export type CalendarPromptEndEvent = CalendarPrompt;

export interface OcrEvent {
  captureId: string;
  noteId: string;
  recognizedText?: string;
}

export const parityEvents = {
  onMeetingChanged(handler: (record: MeetingRecord) => void): Promise<UnlistenFn> {
    return listen<MeetingRecord>("meeting://changed", (event) => handler(event.payload));
  },
  onMeetingProgress(handler: (payload: MeetingProgressEvent) => void): Promise<UnlistenFn> {
    return listen<MeetingProgressEvent>("meeting://progress", (event) => handler(event.payload));
  },
  onMeetingLevel(handler: (payload: LevelEvent) => void): Promise<UnlistenFn> {
    return listen<LevelEvent>("meeting://level", (event) => handler(event.payload));
  },
  onDictationLevel(handler: (payload: LevelEvent) => void): Promise<UnlistenFn> {
    return listen<LevelEvent>("dictation://level", (event) => handler(event.payload));
  },
  onShortcutAction(handler: (payload: ShortcutActionEvent) => void): Promise<UnlistenFn> {
    return listen<ShortcutActionEvent>("shortcut://action", (event) => handler(event.payload));
  },
  onShortcutEscape(handler: () => void): Promise<UnlistenFn> {
    return listen("shortcut://escape", () => handler());
  },
  onCalendarPromptStart(handler: (payload: CalendarPromptStartEvent) => void): Promise<UnlistenFn> {
    return listen<CalendarPromptStartEvent>("calendar://prompt-start", (event) => handler(event.payload));
  },
  onCalendarPromptEnd(handler: (payload: CalendarPromptEndEvent) => void): Promise<UnlistenFn> {
    return listen<CalendarPromptEndEvent>("calendar://prompt-end", (event) => handler(event.payload));
  },
  onCalendarPromptClosed(handler: (payload: { occurrenceId: string; kind: "start" | "end" }) => void): Promise<UnlistenFn> {
    return listen<{ occurrenceId: string; kind: "start" | "end" }>("calendar://prompt-closed", event => handler(event.payload));
  },
  onCalendarError(handler: (message: string) => void): Promise<UnlistenFn> {
    return listen<string>("calendar://error", event => handler(event.payload));
  },
  onCaptureOcr(handler: (payload: OcrEvent) => void): Promise<UnlistenFn> {
    return listen<OcrEvent>("capture://ocr", (event) => handler(event.payload));
  }
};
