export type UUID = string;

export type NoteCaptureKind = "dictation" | "screenshot" | "meeting" | "text";

export interface NoteCapture {
  id: UUID;
  createdAt: string; // ISO-8601 without fractional seconds in UTC with Z
  title: string;
  rawText: string;
  text: string;
  duration: number;
  sourceApplication?: string | null;
  sourceBundleIdentifier?: string | null;
  kind: NoteCaptureKind;
  attachment?: string | null; // e.g. "Screenshot-<UUID>.png"
  meetingID?: UUID | null;
  recognizedText?: string | null;
  superseded?: boolean | null;
}

export interface VoiceNote {
  id: UUID;
  createdAt: string; // ISO-8601 without fractional seconds in UTC with Z
  title: string;
  rawText: string;
  cleanedText: string;
  editedText?: string | null;
  duration: number;
  isPinned: boolean;
  tags: string[];
  source: string; // "Dictation"
  sourceApplication?: string | null;
  sourceBundleIdentifier?: string | null;
  captures?: NoteCapture[] | null; // present => daily note
}

export type MeetingStatus =
  | "recording"
  | "paused"
  | "saved"
  | "transcribing"
  | "summarizing"
  | "ready"
  | "interrupted"
  | "failed";

export interface MeetingSegment {
  id: string; // e.g. "<part>/microphone/chunk-00000.wav"
  track: "microphone" | "system";
  start: number; // floating-point seconds from start
  duration: number; // floating-point seconds
  text: string;
}

export interface SummaryPoint {
  text: string;
  sources: string[]; // segment IDs
}

export interface MeetingSummary {
  overview: SummaryPoint[];
  decisions: SummaryPoint[];
  actions: SummaryPoint[];
}

export interface MeetingSettings {
  speechProvider?: string;
  speechBaseURL?: string;
  speechModel?: string;
  languageModelProvider?: string;
  languageModelBaseURL?: string;
  languageModel?: string;
  customVocabulary?: string[];
  correctionRules?: Array<{ id?: string; heard: string; replacement: string }>;
  speechHints?: boolean;
  microphoneDeviceUID?: string;
}

export interface MeetingRecord {
  id: UUID;
  title: string;
  createdAt: number; // seconds since 2001-01-01T00:00:00Z (unix_seconds - 978307200)
  duration: number; // seconds
  status: MeetingStatus;
  summarizeOnStop: boolean;
  liveTranscription?: boolean | null;
  includesMicrophone: boolean;
  includesSystemAudio: boolean;
  settings: MeetingSettings;
  segments: MeetingSegment[];
  summary: MeetingSummary | null;
  recoveryNotice?: string | null;
  lastError?: string | null;
  microphoneLabel: string;
  systemLabel: string;
  userNotes?: string | null;
  summaryNeedsConfirmation?: boolean | null;
}

export interface FlowbarPlacement {
  screen?: string;
  x: number; // normalized 0..1
  y: number; // normalized 0..1
  edge?: "left" | "right" | null;
}

export type ShortcutAction =
  | "dictate"
  | "holdToTalk"
  | "meeting"
  | "screenshotArea"
  | "screenshotWindow"
  | "screenshotScreen"
  | "pasteLast";

export interface ShortcutBinding {
  accelerator: string;
  display: string;
}

export interface Snippet {
  id: string;
  trigger: string;
  replacement: string;
}

export interface CorrectionRule {
  id: string;
  heard: string;
  replacement: string;
}

export interface CalendarSource {
  id: string;
  name: string;
  url?: string;
  file?: string;
}

export interface CalendarEvent {
  id: string;
  occurrenceId?: string;
  title: string;
  start: string; // ISO
  end: string; // ISO
  location?: string;
  url?: string;
  isMeeting?: boolean;
  calendarID: string;
  calendarName: string;
  link?: string | null;
  hasAttendees: boolean;
  excluded: boolean;
  isAllDay: boolean;
}

export interface ParitySettings {
  hasCompletedSetup?: boolean;
  speechProvider: string;
  speechBaseURL: string;
  speechModel: string;
  languageModelProvider: string;
  languageModelBaseURL: string;
  languageModel: string;
  writingTone: "natural" | "casual" | "formal";
  customVocabulary: string[];
  correctionRules: CorrectionRule[];
  cleanupStrength: "light" | "clear" | "concise";
  speechHints: boolean;
  spokenCorrections: boolean;
  learnSpelledWords: boolean;
  correctionModel: string;
  dictationLiveTranscription: boolean;
  meetingLiveTranscription: boolean;
  calendarEnabled: boolean;
  calendarExcludedTitles: string[];
  calendarAutoStart: boolean;
  calendarMeetingsOnly: boolean;
  calendarSummarize: boolean;
  microphoneDeviceUID: string;
  interactionSounds: boolean;
  snippets: Snippet[];
  appWritingTones: Record<string, string>;
  cleanupEnabled: boolean;
  pasteIntoFocusedApp: boolean;
  saveRawAudio: boolean;
  showOverlayWhenIdle: boolean;
  theme: "system" | "light" | "dark";
  overlayPosition?: string;
  flowbarPlacement?: FlowbarPlacement | null;
  meetingMicrophone: boolean;
  meetingSystemAudio: boolean;
  meetingSummarize: boolean;

  // Desktop-only keys
  shortcuts: Partial<Record<ShortcutAction, ShortcutBinding>>;
  systemAudioDeviceId: string;
  calendarSources: CalendarSource[];
}

export interface ProfileLoadResult {
  settings: ParitySettings;
  notes: VoiceNote[];
  storageError?: string;
}
