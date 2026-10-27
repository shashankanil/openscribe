import { describe, expect, it } from "vitest";
import { confirmationFeedback, deriveMode, meetingHint, modeLength } from "./mode";
import { menuEntries } from "./menu";

describe("native Flowbar modes", () => {
  it("prioritizes meetings, saving and dictation over confirmations and hover", () => {
    expect(deriveMode("recording", true, true, "Saved", true)).toBe("meeting");
    expect(deriveMode("recording", false, true, "Saved", true)).toBe("meetingSaving");
    expect(deriveMode("recording", false, false, "Saved", true)).toBe("dictating");
    for (const phase of ["starting", "transcribing", "cleaning"] as const) {
      expect(deriveMode(phase, false, false, "Saved", true)).toBe("processing");
    }
  });
  it("shows an explicit save confirmation rather than inferring success from idle", () => {
    expect(deriveMode("idle", false, false, "Saved", true)).toBe("confirmation");
    expect(deriveMode("idle", false, false, null, true)).toBe("idleExpanded");
    expect(deriveMode("idle", false, false, null, false)).toBe("idle");
  });
  it("matches the fixed native state lengths", () => {
    expect(modeLength("idle", false)).toBe(34);
    expect(modeLength("idleExpanded", true)).toBe(150);
    expect(modeLength("confirmation", true)).toBe(52);
    expect(modeLength("meeting", false)).toBe(84);
    expect(modeLength("meeting", true)).toBe(140);
    for (const mode of ["dictating", "processing", "meetingSaving"] as const) expect(modeLength(mode, true)).toBe(88);
  });
  it("uses native confirmation copy and timings, and excludes cancellation", () => {
    expect(confirmationFeedback("Saved", false)).toEqual({ message: "Saved", duration: 1100 });
    expect(confirmationFeedback("Pasted", false)).toEqual({ message: "Pasted", duration: 1600 });
    expect(confirmationFeedback("Screenshot saved", false)).toEqual({ message: "Added to today", duration: 1600 });
    expect(confirmationFeedback("Screenshot saved", true)).toEqual({ message: "Added to meeting", duration: 1600 });
    expect(confirmationFeedback("Cancelled", false)).toBeNull();
  });
  it("matches native meeting duration and shortcut help, including hour boundaries", () => {
    expect(meetingHint(65.6, "Ctrl Alt M")).toBe("Meeting · 1:06 · click for notes · Ctrl Alt M to stop");
    expect(meetingHint(3599.6)).toBe("Meeting · 1:00:00 · click for notes");
    expect(meetingHint(-1)).toBe("Meeting · 0:00 · click for notes");
  });
});

describe("native Flowbar menu", () => {
  it("keeps native order and routes workspace, shortcuts and settings separately", () => {
    const entries = menuEntries("idleExpanded", false, true);
    expect(entries.map(e => e.label).filter(Boolean)).toEqual(["Today’s note", "Open OpenScribe", "Position", "Keep on screen when idle", "Shortcuts…", "Settings…"]);
    expect(entries.find(e => e.id === "shortcuts")?.intent).toEqual({ action: "settings", section: "shortcuts" });
    expect(entries.find(e => e.id === "keep")).toMatchObject({ checked: true, intent: { action: "updatePreference", key: "showOverlayWhenIdle", value: false } });
    expect(menuEntries("idleExpanded", false, false).find(e => e.id === "keep")?.intent).toMatchObject({ value: true });
  });
  it("exposes save and destructive cancellation only in capture modes", () => {
    expect(menuEntries("dictating", false, false).slice(-2)).toMatchObject([
      { label: "Stop and save", intent: { action: "dictate" } },
      { label: "Cancel recording", destructive: true, intent: { action: "cancelDictation" } }
    ]);
    expect(menuEntries("processing", false, false).at(-1)).toMatchObject({ label: "Cancel", destructive: true });
    for (const mode of ["idle", "confirmation", "meetingSaving"] as const) {
      expect(menuEntries(mode, false, false).some(e => e.destructive)).toBe(false);
    }
  });
  it("offers notes, pause/resume and stop during a meeting", () => {
    expect(menuEntries("meeting", false, false).slice(-3).map(e => e.label)).toEqual(["Meeting notes…", "Pause meeting", "Stop meeting and save"]);
    expect(menuEntries("meeting", true, false).find(e => e.id === "pause")).toMatchObject({ label: "Resume meeting", intent: { action: "pauseMeeting" } });
  });
});
