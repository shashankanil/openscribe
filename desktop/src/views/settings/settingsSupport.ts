import { invoke } from "@tauri-apps/api/core";
import type { ParitySettings } from "../../api/parityTypes";
export type SaveSettings = (settings: ParitySettings) => void | Promise<void>;
export interface SourceApp { id: string; name: string; path: string }
export interface ReadinessItem { ready: boolean; detail: string }
export interface CaptureReadiness { microphone: ReadinessItem; systemAudio: ReadinessItem; paste: ReadinessItem; calendar: ReadinessItem }
export const settingsNative = {
  getLaunchAtLogin: () => invoke<boolean>("get_launch_at_login"),
  setLaunchAtLogin: (enabled: boolean) => invoke<void>("set_launch_at_login", { enabled }),
  listSourceApps: () => invoke<SourceApp[]>("list_source_apps"),
  captureReadiness: () => invoke<CaptureReadiness>("capture_readiness"),
  openWindowsSettings: (section: "microphone" | "sound") => invoke<void>("open_windows_settings", { section })
};
export const tones = ["natural", "casual", "formal"] as const;
export const cleanupDescriptions = {
  light: "Fix punctuation and capitalization only. Keep the speaker's wording, repetitions and fillers. Do not apply a different tone.",
  clear: "Remove filler words, false starts and accidental repetition. Resolve explicit spoken corrections. Preserve all substantive details.",
  concise: "Remove fillers and tighten redundant phrasing. Preserve every fact, qualification, uncertainty, number and negation. Never summarize away details."
};
export function canPractice(readiness: CaptureReadiness | null, hasKey: boolean, paste: boolean) {
  return hasKey && !!readiness?.microphone.ready && (!paste || !!readiness.paste.ready);
}

export function connectionValidation(endpoint: string, model: string): string | null {
  if (!model.trim()) return "Enter a model ID.";
  try {
    const url = new URL(endpoint.trim());
    if (!["http:", "https:"].includes(url.protocol) || !url.hostname || url.hostname.toLowerCase() === "example.com" || url.username || url.password) throw new Error();
  } catch { return "Enter a valid HTTP or HTTPS server address."; }
  return null;
}
export function speechHintDetail(provider: string, model: string): string | null {
  const id = model.toLowerCase();
  switch (provider) {
    case "openRouter":
      if (id.startsWith("mistralai/")) return "Voxtral spells your words using Mistral context biasing.";
      return id.startsWith("openai/") || id.includes("whisper") ? "Your words are sent to the speech model as a glossary." : null;
    case "openAI": case "groq": return "Your words are sent to the speech model as a glossary.";
    case "mistral": return "Voxtral spells your words using context biasing.";
    case "deepgram": return id.startsWith("nova-3") ? "Deepgram boosts your words as key terms." : "Deepgram boosts your words as keywords.";
    case "assemblyAI": return "AssemblyAI boosts your words.";
    case "custom": return "Sent as a glossary prompt, if your endpoint supports one.";
    default: return null;
  }
}
