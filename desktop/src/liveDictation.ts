import { invoke } from "@tauri-apps/api/core";

export interface DictationPartial { path: string; text: string; hint: string }
/** Stop capture before waiting for a final transcript; cancellation closes the live socket. */
export const stopLiveRecording = (cancel = false) => invoke<{ path: string; duration: number; transcript?: string | null }>("stop_recording", { cancel });
