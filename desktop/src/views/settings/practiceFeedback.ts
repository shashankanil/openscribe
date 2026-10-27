export type PracticeFeedback = {
  status: "none" | "requested" | "active" | "ended" | "saved" | "cancelled" | "failed";
  baselineTranscript: string;
  baselineHint: string;
  cancelRequested: boolean;
};
export type PracticeEvent =
  | { type: "request"; transcript: string; hint: string }
  | { type: "phase"; phase: string; transcript: string; hint: string }
  | { type: "confirmation"; message: string }
  | { type: "cancel" }
  | { type: "failure" };
export const initialPractice: PracticeFeedback = { status: "none", baselineTranscript: "", baselineHint: "", cancelRequested: false };
export function practiceFeedback(state: PracticeFeedback, event: PracticeEvent): PracticeFeedback {
  switch (event.type) {
    case "request": return { status: "requested", baselineTranscript: event.transcript, baselineHint: event.hint, cancelRequested: false };
    case "cancel": return { ...state, cancelRequested: true, status: "cancelled" };
    case "failure": return { ...state, status: "failed" };
    case "confirmation":
      if (!["requested", "active", "ended"].includes(state.status)) return state;
      if (event.message === "Cancelled") return { ...state, status: "cancelled" };
      if (event.message === "Saved" && state.status !== "requested" && !state.cancelRequested) return { ...state, status: "saved" };
      return state;
    case "phase": {
      const active = ["starting", "recording", "transcribing", "cleaning"].includes(event.phase);
      if (state.status === "saved" && event.hint && event.hint !== state.baselineHint) return { ...state, status: "failed" };
      // A shortcut may start practice without the button.
      if (active && state.status === "none" && !state.cancelRequested) {
        return { status: "active", baselineTranscript: event.transcript, baselineHint: event.hint, cancelRequested: false };
      }
      if (["requested", "active", "ended"].includes(state.status)) {
        if (event.phase === "error" || (event.hint && event.hint !== state.baselineHint)) return { ...state, status: "failed" };
        if (active) return { ...state, status: "active" };
        if (state.status === "active" && event.phase === "idle") return { ...state, status: "ended" };
      }
      return state;
    }
  }
}
export function practiceTranscript(state: PracticeFeedback, transcript: string): string {
  return state.status === "saved" && !state.cancelRequested ? transcript : "";
}
