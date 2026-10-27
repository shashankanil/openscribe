import { describe, expect, it, vi } from "vitest";
import { initialPractice, practiceFeedback, practiceTranscript, type PracticeFeedback } from "./practiceFeedback";
import { readSetupReadiness } from "./setupReadiness";
import type { CaptureReadiness } from "./settingsSupport";
const request = () => practiceFeedback(initialPractice, { type: "request", transcript: "Old note", hint: "" });
const phase = (state: PracticeFeedback, value: string, hint = "") => practiceFeedback(state, { type: "phase", phase: value, transcript: "Old note", hint });
describe("setup practice reports only confirmed saves", () => {
  it("does not display an old transcript after an intent or idle transition", () => {
    const state = phase(request(), "idle");
    expect(state.status).toBe("requested");
    expect(practiceTranscript(state, "Old note")).toBe("");
    expect(practiceFeedback(state, { type: "confirmation", message: "Saved" }).status).toBe("requested");
  });
  it("waits for a save confirmation after recording and processing end", () => {
    let state = phase(request(), "recording");
    state = phase(state, "transcribing");
    state = phase(state, "idle");
    expect(state.status).toBe("ended");
    expect(practiceTranscript(state, "New note")).toBe("");
    state = practiceFeedback(state, { type: "confirmation", message: "Saved" });
    expect(state.status).toBe("saved");
    expect(practiceTranscript(state, "New note")).toBe("New note");
  });
  it("keeps controller errors failed even when phase later returns idle or a late confirmation arrives", () => {
    let state = phase(request(), "recording");
    state = phase(state, "idle", "Transcription failed");
    state = phase(state, "idle", "Transcription failed");
    state = practiceFeedback(state, { type: "confirmation", message: "Saved" });
    expect(state.status).toBe("failed"); expect(practiceTranscript(state, "Old note")).toBe("");
  });
  it("does not leave a success message when a delayed recording error arrives", () => {
    let state = phase(request(), "recording");
    state = practiceFeedback(state, { type: "confirmation", message: "Saved" });
    state = phase(state, "idle", "Recording failed");
    expect(state.status).toBe("failed"); expect(practiceTranscript(state, "Old note")).toBe("");
  });
  it("suppresses success immediately after cancellation, including late save events", () => {
    let state = phase(request(), "recording");
    state = practiceFeedback(state, { type: "cancel" });
    state = phase(state, "transcribing");
    state = practiceFeedback(state, { type: "confirmation", message: "Saved" });
    state = phase(state, "idle");
    expect(state.status).toBe("cancelled"); expect(practiceTranscript(state, "Old note")).toBe("");
  });
  it("handles cancellation through the global shortcut and unrelated confirmations", () => {
    let state = phase(request(), "recording");
    expect(practiceFeedback(state, { type: "confirmation", message: "Screenshot saved" })).toEqual(state);
    state = practiceFeedback(state, { type: "confirmation", message: "Cancelled" });
    expect(state.status).toBe("cancelled"); expect(practiceTranscript(state, "Old note")).toBe("");
  });
  it("keeps intent-dispatch failures failed until a deliberate new attempt", () => {
    let state = practiceFeedback(request(), { type: "failure" });
    state = phase(state, "idle");
    expect(state.status).toBe("failed");
    state = practiceFeedback(state, { type: "request", transcript: "Old note", hint: "" });
    expect(phase(state, "recording").status).toBe("active");
  });
  it("tracks practice started with a global shortcut without inferring success", () => {
    const state = phase(initialPractice, "recording");
    expect(state.status).toBe("active"); expect(practiceTranscript(state, "Old note")).toBe("");
  });
});
describe("fresh setup readiness checks", () => {
  const capture: CaptureReadiness = { microphone: { ready: true, detail: "Available" }, paste: { ready: false, detail: "Unavailable" }, systemAudio: { ready: false, detail: "Optional" }, calendar: { ready: false, detail: "No sources" } };
  it("rechecks keys and capture access on every call rather than reusing cached readiness", async () => {
    const key = vi.fn().mockResolvedValueOnce(true).mockResolvedValueOnce(false);
    const devices = vi.fn().mockResolvedValue(capture);
    expect((await readSetupReadiness(false, key, devices)).ready).toBe(true);
    expect((await readSetupReadiness(false, key, devices)).ready).toBe(false);
    expect(key).toHaveBeenCalledTimes(2); expect(devices).toHaveBeenCalledTimes(2);
  });
  it("requires paste only when enabled and never substitutes a permission grant", async () => {
    expect((await readSetupReadiness(true, async () => true, async () => capture)).ready).toBe(false);
    expect((await readSetupReadiness(false, async () => true, async () => capture)).ready).toBe(true);
  });
  it("propagates a native readiness failure instead of returning a ready result", async () => {
    await expect(readSetupReadiness(false, async () => true, async () => { throw new Error("Device removed"); })).rejects.toThrow("Device removed");
  });
});
