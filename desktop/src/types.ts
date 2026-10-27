export type Section = "notes" | "meetings" | "calendar" | "settings";
export type CapturePhase = "idle" | "recording" | "transcribing" | "cleaning";
export type ProviderID = "openRouter" | "openAI" | "groq" | "deepgram" | "assemblyAI" | "mistral" | "anthropic" | "google" | "custom";

export interface ProviderChoice {
  id: ProviderID;
  title: string;
  baseUrl: string;
  speechModel?: string;
  writingModel?: string;
}

export interface AppSettings {
  speechProvider: ProviderID;
  speechBaseUrl: string;
  speechModel: string;
  writingProvider: ProviderID;
  writingBaseUrl: string;
  writingModel: string;
  cleanupEnabled: boolean;
  cleanupStrength: "light" | "clear" | "concise";
  writingTone: "natural" | "casual" | "formal";
  pasteIntoFocusedApp: boolean;
  saveRawAudio: boolean;
  shortcut: string;
  microphoneDeviceId: string;
  systemAudioDeviceId: string;
  customVocabulary: string[];
  snippets: Snippet[];
  corrections: Correction[];
  theme: "paper" | "dark";
}

export interface Note {
  id: string;
  createdAt: string;
  title: string;
  rawText: string;
  cleanedText: string;
  duration: number;
  pinned: boolean;
  tags: string[];
  audioPath?: string;
}

export interface Meeting {
  id: string;
  createdAt: string;
  title: string;
  duration: number;
  transcript: string;
  summary: string;
  audioPath?: string;
  sourceLabel: string;
}

export interface CalendarEvent {
  id: string;
  title: string;
  start: string;
  end: string;
  location?: string;
  url?: string;
}

export interface Snippet { id: string; trigger: string; replacement: string }
export interface Correction { id: string; heard: string; replacement: string }
export interface AudioInput { id: string; name: string; likelySystemAudio: boolean }

export interface RecoveryJob {
  id: string;
  path: string;
  duration: number;
  createdAt: string;
  kind: "dictation" | "meeting";
  title?: string;
  sourceLabel?: string;
  summarize?: boolean;
}

export interface PersistedState {
  settings: AppSettings;
  notes: Note[];
  meetings: Meeting[];
  calendar: CalendarEvent[];
  recoveries: RecoveryJob[];
  setupCompleted: boolean;
}
