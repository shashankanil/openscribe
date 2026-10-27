import { invoke } from "@tauri-apps/api/core";
import type { AppSettings, AudioInput } from "./types";
import type { ParitySettings } from "./api/parityTypes";

type Settings = AppSettings | ParitySettings;
export interface SourceApp { id: string; name: string; path: string }
export interface AccessStatus { ready: boolean; detail: string }
export interface CaptureReadiness { microphone: AccessStatus; systemAudio: AccessStatus; paste: AccessStatus; calendar: AccessStatus }
export const speechAccount = (settings: Settings) => `speech:${settings.speechProvider}:${"speechBaseURL" in settings ? settings.speechBaseURL : settings.speechBaseUrl}`;
export const writingAccount = (settings: Settings) => "languageModelProvider" in settings ? `writing:${settings.languageModelProvider}:${settings.languageModelBaseURL}` : `writing:${settings.writingProvider}:${settings.writingBaseUrl}`;

export const config = (settings: Settings, purpose: "speech" | "writing") => purpose === "speech" ? {
  provider: settings.speechProvider,
  baseUrl: "speechBaseURL" in settings ? settings.speechBaseURL : settings.speechBaseUrl,
  model: settings.speechModel,
  credentialAccount: speechAccount(settings)
} : {
  provider: "languageModelProvider" in settings ? settings.languageModelProvider : settings.writingProvider,
  baseUrl: "languageModelBaseURL" in settings ? settings.languageModelBaseURL : settings.writingBaseUrl,
  model: "languageModel" in settings ? settings.languageModel : settings.writingModel,
  credentialAccount: writingAccount(settings)
};

export const native = {
  foregroundApp: () => invoke<SourceApp | null>("get_foreground_app"),
  captureReadiness: () => invoke<CaptureReadiness>("capture_readiness"),
  cancelDictationWork: () => invoke<void>("cancel_dictation_work"),
  listInputs: () => invoke<AudioInput[]>("list_audio_inputs"),
  startRecording: (deviceId?: string) => invoke<string>("start_recording", { deviceId: deviceId || null }),
  stopRecording: () => invoke<{ path: string; duration: number }>("stop_recording"),
  deleteRecording: (path: string) => invoke<void>("delete_recording", { path }),
  transcribe: (path: string, settings: Settings, hints?: { prompt: string | null; terms: string[] }) => invoke<{ text: string }>("transcribe_recording", { path, config: config(settings, "speech"), ...(hints === undefined ? {} : { hints }) }),
  clean: (text: string, settings: Settings, instruction: string) => invoke<{ text: string }>("clean_transcript", { text, config: config(settings, "writing"), instruction }),
  setDictationBusy: (busy: boolean) => invoke<void>("set_dictation_busy", { busy }),
  saveCredential: (account: string, secret: string) => invoke<void>("save_credential", { account, secret }),
  hasCredential: (account: string) => invoke<boolean>("has_credential", { account }),
  copyCredential: (from: string, to: string) => invoke<void>("copy_credential", { from, to }),
  removeCredential: (account: string) => invoke<void>("remove_credential", { account }),
  paste: (text: string) => invoke<void>("paste_text", { text })
};

export function friendlyError(error: unknown): string {
  const raw = String(error ?? "").toLowerCase();
  if (raw.includes("401") || raw.includes("unauthorized") || raw.includes("invalid api key")) return "Check your provider key in Settings.";
  if (raw.includes("403") || raw.includes("forbidden")) return "This account can’t use that model. Check Settings and try again.";
  if (raw.includes("429") || raw.includes("rate limit")) return "Provider limit reached. Try again shortly.";
  if (raw.includes("timeout") || raw.includes("network") || raw.includes("offline")) return "Connection interrupted. Check your network and retry.";
  if (raw.includes("unreadable") || raw.includes("malformed") || raw.includes("decode")) return "That result wasn’t usable. Please try again.";
  if (raw.includes("no speech") || raw.includes("too short")) return "We couldn’t find enough speech. Try recording again.";
  if (raw.includes("provider request failed") || raw.includes("http 4") || raw.includes("http 5")) return "The provider couldn’t complete this request. Please try again.";
  if (raw.includes("audio") || raw.includes("microphone") || raw.includes("device")) return "The selected audio source isn’t available. Check Audio settings.";
  return "OpenScribe couldn’t finish that. Please try again.";
}
