import type { AppSettings, PersistedState, ProviderChoice } from "./types";

export const providers: ProviderChoice[] = [
  { id: "openRouter", title: "OpenRouter", baseUrl: "https://openrouter.ai/api/v1", speechModel: "mistralai/voxtral-mini-transcribe", writingModel: "openai/gpt-4o-mini" },
  { id: "openAI", title: "OpenAI", baseUrl: "https://api.openai.com/v1", speechModel: "gpt-4o-mini-transcribe", writingModel: "gpt-4o-mini" },
  { id: "groq", title: "Groq", baseUrl: "https://api.groq.com/openai/v1", speechModel: "whisper-large-v3-turbo", writingModel: "llama-3.3-70b-versatile" },
  { id: "deepgram", title: "Deepgram", baseUrl: "https://api.deepgram.com/v1", speechModel: "nova-3" },
  { id: "assemblyAI", title: "AssemblyAI", baseUrl: "https://api.assemblyai.com/v2", speechModel: "best" },
  { id: "mistral", title: "Mistral", baseUrl: "https://api.mistral.ai/v1", speechModel: "voxtral-mini-latest" },
  { id: "anthropic", title: "Anthropic", baseUrl: "https://api.anthropic.com", writingModel: "claude-haiku-4-5-20251001" },
  { id: "google", title: "Google Gemini", baseUrl: "https://generativelanguage.googleapis.com", writingModel: "gemini-3.7-flash" },
  { id: "custom", title: "Custom compatible endpoint", baseUrl: "https://example.com/v1", speechModel: "whisper-1", writingModel: "gpt-4o-mini" }
];

export const defaultSettings: AppSettings = {
  speechProvider: "openRouter",
  speechBaseUrl: providers[0].baseUrl,
  speechModel: providers[0].speechModel!,
  writingProvider: "openRouter",
  writingBaseUrl: providers[0].baseUrl,
  writingModel: providers[0].writingModel!,
  cleanupEnabled: true,
  cleanupStrength: "clear",
  writingTone: "natural",
  pasteIntoFocusedApp: true,
  saveRawAudio: false,
  shortcut: "Alt+Space",
  microphoneDeviceId: "",
  systemAudioDeviceId: "",
  customVocabulary: [],
  snippets: [],
  corrections: [],
  theme: "paper"
};

export const initialState: PersistedState = {
  settings: defaultSettings,
  notes: [],
  meetings: [],
  calendar: [],
  recoveries: [],
  setupCompleted: false
};

export function providerDefaults(id: string, purpose: "speech" | "writing") {
  const provider = providers.find((item) => item.id === id) ?? providers[0];
  return { baseUrl: provider.baseUrl, model: purpose === "speech" ? provider.speechModel ?? "whisper-1" : provider.writingModel ?? "gpt-4o-mini" };
}

export const cleanupInstructions = {
  light: "Fix punctuation and capitalization only. Keep the speaker’s wording, repetitions and fillers.",
  clear: "Remove filler words, false starts and accidental repetition. Resolve spoken corrections. Preserve every substantive detail.",
  concise: "Remove fillers and tighten redundant phrasing. Preserve every fact, number, qualification, uncertainty and negation."
};
