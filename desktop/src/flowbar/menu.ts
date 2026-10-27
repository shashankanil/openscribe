import type { WorkspaceIntent } from "../workspaceEvents";
import type { FlowbarMode } from "./mode";

export interface FlowbarMenuEntry {
  id: string;
  label?: string;
  intent?: WorkspaceIntent;
  destructive?: boolean;
  checked?: boolean;
}

/** Native context-menu order and state-specific actions from FlowbarView.menu. */
export function menuEntries(mode: FlowbarMode, paused: boolean, keepVisible: boolean): FlowbarMenuEntry[] {
  const entries: FlowbarMenuEntry[] = [
    { id: "today", label: "Today’s note", intent: { action: "open", section: "notes" } },
    { id: "workspace", label: "Open OpenScribe", intent: { action: "open" } },
    { id: "separator-main" },
    { id: "position", label: "Position" },
    { id: "keep", label: "Keep on screen when idle", checked: keepVisible, intent: { action: "updatePreference", key: "showOverlayWhenIdle", value: !keepVisible } },
    { id: "shortcuts", label: "Shortcuts…", intent: { action: "settings", section: "shortcuts" } },
    { id: "settings", label: "Settings…", intent: { action: "settings", section: "general" } }
  ];
  if (mode === "dictating") entries.push(
    { id: "separator-capture" },
    { id: "save", label: "Stop and save", intent: { action: "dictate" } },
    { id: "cancel", label: "Cancel recording", destructive: true, intent: { action: "cancelDictation" } }
  );
  if (mode === "processing") entries.push(
    { id: "separator-capture" },
    { id: "cancel", label: "Cancel", destructive: true, intent: { action: "cancelDictation" } }
  );
  if (mode === "meeting") entries.push(
    { id: "separator-meeting" },
    { id: "meeting-notes", label: "Meeting notes…" },
    { id: "pause", label: paused ? "Resume meeting" : "Pause meeting", intent: { action: "pauseMeeting" } },
    { id: "stop", label: "Stop meeting and save", intent: { action: "meeting" } }
  );
  return entries;
}
