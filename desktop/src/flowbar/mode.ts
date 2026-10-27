import type { DictationPhase } from "../dictation";

export type FlowbarMode = "idle" | "idleExpanded" | "dictating" | "processing" | "confirmation" | "meeting" | "meetingSaving";

/** Keep capture states ahead of transient confirmations, as in OverlayPanel.swift. */
export function deriveMode(phase: DictationPhase, meeting: boolean, saving: boolean, confirmation: string | null, expanded: boolean): FlowbarMode {
  if (meeting) return "meeting";
  if (saving) return "meetingSaving";
  if (phase === "recording") return "dictating";
  if (phase !== "idle") return "processing";
  if (confirmation) return "confirmation";
  return expanded ? "idleExpanded" : "idle";
}

export function modeLength(mode: FlowbarMode, expanded: boolean): number {
  switch (mode) {
    case "idle": return 34;
    case "idleExpanded": return 150;
    case "confirmation": return 52;
    case "meeting": return expanded ? 140 : 84;
    default: return 88;
  }
}

export function confirmationFeedback(message: string, inMeeting: boolean): { message: string; duration: number } | null {
  // Cancelling a recording is not a successful save.
  if (message === "Cancelled") return null;
  if (message === "Screenshot saved") return { message: inMeeting ? "Added to meeting" : "Added to today", duration: 1600 };
  return { message, duration: message === "Saved" ? 1100 : 1600 };
}

export const positionPresets = [
  ["Bottom center", "bottom-center"], ["Bottom left", "bottom-left"], ["Bottom right", "bottom-right"],
  ["Top center", "top-center"], ["Top right", "top-right"]
] as const;

export function meetingHint(elapsed: number, shortcut?: string): string {
  const seconds = Number.isFinite(elapsed) ? Math.max(0, Math.round(elapsed)) : 0;
  const pad = (value: number) => String(value).padStart(2, "0");
  const time = seconds >= 3600 ? `${Math.floor(seconds / 3600)}:${pad(Math.floor(seconds / 60) % 60)}:${pad(seconds % 60)}`
    : `${Math.floor(seconds / 60)}:${pad(seconds % 60)}`;
  return `Meeting · ${time} · click for notes${shortcut ? ` · ${shortcut} to stop` : ""}`;
}
