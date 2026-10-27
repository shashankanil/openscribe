import { emitTo } from "@tauri-apps/api/event";
import type { FlowbarPlacement, MeetingRecord, ParitySettings } from "./api/parityTypes";
import type { DictationPhase } from "./dictation";

export type WorkspaceIntent =
  | { action: "settings"; section: "general" | "providers" | "shortcuts" | "personalize" | "calendar" | "privacy" | "permissions" }
  | { action: "inspectNotice" }
  | { action: "updatePreference"; key: "overlayPosition" | "showOverlayWhenIdle"; value: string | boolean }
  | { action: "dictate" | "cancelDictation" | "meeting" | "pauseMeeting" | "pasteLast" | "dismissNotice" }
  | { action: "screenshot"; kind: "area" | "window" | "screen" }
  | { action: "placement"; placement: FlowbarPlacement }
  | { action: "open"; section?: "notes" | "meetings" | "settings"; meetingId?: string };
export interface WorkspaceStatus { phase: DictationPhase; settings: ParitySettings; activeMeeting: MeetingRecord | null; processingMeeting: boolean; notice: string | null; currentTranscript?: string; captureHint?: string }
export const sendIntent = (intent: WorkspaceIntent) => emitTo("main", "workspace://intent", intent);
export const reportUiError = (error: unknown) => {
  const message = String(error);
  window.dispatchEvent(new CustomEvent("workspace-error", { detail: message }));
  void emitTo("main", "workspace://error", message).catch(console.error);
};
