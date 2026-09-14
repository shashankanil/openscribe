import { invoke } from "@tauri-apps/api/core";
import { readText, writeText } from "@tauri-apps/plugin-clipboard-manager";
import type { AppSettings, AudioInput } from "./types";

export const speechAccount = (settings: AppSettings) => `speech:${settings.speechProvider}:${settings.speechBaseUrl}`;
export const writingAccount = (settings: AppSettings) => `writing:${settings.writingProvider}:${settings.writingBaseUrl}`;

const config = (settings: AppSettings, purpose: "speech" | "writing") => purpose === "speech" ? {
  provider: settings.speechProvider,
  baseUrl: settings.speechBaseUrl,
  model: settings.speechModel,
  credentialAccount: speechAccount(settings)
} : {
  provider: settings.writingProvider,
  baseUrl: settings.writingBaseUrl,
  model: settings.writingModel,
  credentialAccount: writingAccount(settings)
};

export const native = {
  listInputs: () => invoke<AudioInput[]>("list_audio_inputs"),
  startRecording: (deviceId?: string) => invoke<string>("start_recording", { deviceId: deviceId || null }),
  stopRecording: () => invoke<{ path: string; duration: number }>("stop_recording"),
  deleteRecording: (path: string) => invoke<void>("delete_recording", { path }),
  transcribe: (path: string, settings: AppSettings) => invoke<{ text: string }>("transcribe_recording", { path, config: config(settings, "speech") }),
  clean: (text: string, settings: AppSettings, instruction: string) => invoke<{ text: string }>("clean_transcript", { text, config: config(settings, "writing"), instruction }),
  saveCredential: (account: string, secret: string) => invoke<void>("save_credential", { account, secret }),
  hasCredential: (account: string) => invoke<boolean>("has_credential", { account }),
  removeCredential: (account: string) => invoke<void>("remove_credential", { account }),
  async paste(text: string) {
    const previous = await readText().catch(() => "");
    await writeText(text);
    await invoke("paste_keystroke");
    await new Promise((resolve) => setTimeout(resolve, 700));
    if ((await readText().catch(() => "")) === text) await writeText(previous);
  }
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
