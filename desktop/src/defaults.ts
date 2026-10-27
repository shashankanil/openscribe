import type { AppSettings, PersistedState, ProviderChoice } from "./types";

export const providers: ProviderChoice[] = [
  { id: "openRouter", title: "OpenRouter", baseUrl: "https://openrouter.ai/api/v1", speechModel: "mistralai/voxtral-mini-transcribe", writingModel: "openai/gpt-5.6-luna" },
  { id: "openAI", title: "OpenAI", baseUrl: "https://api.openai.com/v1", speechModel: "gpt-4o-mini-transcribe", writingModel: "gpt-5.6-luna" },
  { id: "groq", title: "Groq", baseUrl: "https://api.groq.com/openai/v1", speechModel: "whisper-large-v3-turbo", writingModel: "llama-3.3-70b-versatile" },
  { id: "deepgram", title: "Deepgram", baseUrl: "https://api.deepgram.com/v1", speechModel: "nova-3" },
  { id: "assemblyAI", title: "AssemblyAI", baseUrl: "https://api.assemblyai.com/v2", speechModel: "best" },
  { id: "mistral", title: "Mistral", baseUrl: "https://api.mistral.ai/v1", speechModel: "voxtral-mini-transcribe-realtime-2602" },
  { id: "anthropic", title: "Anthropic", baseUrl: "https://api.anthropic.com", writingModel: "claude-3-5-haiku-latest" },
  { id: "google", title: "Google Gemini", baseUrl: "https://generativelanguage.googleapis.com", speechModel: "gemini-3.5-flash-lite", writingModel: "gemini-3.5-flash-lite" },
  { id: "custom", title: "Custom compatible endpoint", baseUrl: "https://example.com/v1", speechModel: "whisper-1", writingModel: "gpt-4o-mini" }
];

/** Economical presets; selecting a provider never changes an existing saved connection. */
export function modelPresets(provider: string, purpose: "speech" | "writing") {
  if (provider === "openAI") return purpose === "speech" ? [
    { id: "gpt-4o-mini-transcribe", label: "GPT-4o mini transcribe — economical · ~$0.003/min" },
    { id: "gpt-4o-transcribe", label: "GPT-4o transcribe — higher accuracy · ~$0.006/min" }
  ] : [{ id: "gpt-5.6-luna", label: "GPT-5.6 Luna — $0.20 input / $1.20 output per 1M tokens" }];
  if (provider === "google") return [{ id: "gemini-3.5-flash-lite", label: "Gemini 3.5 Flash-Lite — $0.30 input / $2.50 output per 1M tokens" }];
  const choice = providers.find(item => item.id === provider);
  const id = purpose === "speech" ? choice?.speechModel : choice?.writingModel;
  return id && provider !== "custom" ? [{ id, label: id }] : [];
}

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
  shortcut: "Ctrl+Alt+Space",
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

/** Prompt for the dictation cleanup model. Light cleanup keeps the speaker's tone. */
export function cleanupInstruction(settings: Pick<AppSettings, "cleanupStrength" | "writingTone" | "customVocabulary">): string {
  const lines = [cleanupInstructions[settings.cleanupStrength]];
  if (settings.cleanupStrength !== "light") lines.push(`Use a ${settings.writingTone} tone.`);
  lines.push(
    "Correct words the speech recognizer clearly misheard when the surrounding sentence makes the intended word obvious, without inventing content.",
    "Keep the speaker's language and script exactly as spoken. Never translate: romanised Hindi stays romanised, Devanagari stays Devanagari, and mixed Hindi-English stays mixed.",
    "Fix sentence boundaries and punctuation."
  );
  const terms = settings.customVocabulary.map(term => term.trim()).filter(term => term.length > 0);
  if (terms.length > 0) {
    lines.push(`The speaker's dictionary: ${terms.join(", ")}. Always spell these exactly as listed. If a word in the transcript is clearly a mis-hearing of one of them (it sounds alike and fits the context), use the dictionary spelling. Leave ordinary words that merely resemble an entry alone.`);
  }
  lines.push("Return only the revised text.");
  return lines.join("\n");
}
