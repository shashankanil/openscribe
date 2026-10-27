import type { ParitySettings } from "./api/parityTypes";
import { defaultBindings } from "./core/shortcuts";

export const defaultParitySettings: ParitySettings = {
  speechProvider: "openRouter", speechBaseURL: "https://openrouter.ai/api/v1", speechModel: "mistralai/voxtral-mini-transcribe",
  languageModelProvider: "openRouter", languageModelBaseURL: "https://openrouter.ai/api/v1", languageModel: "openai/gpt-5.6-luna",
  writingTone: "natural", customVocabulary: [], correctionRules: [], cleanupStrength: "clear", speechHints: true,
  spokenCorrections: true, learnSpelledWords: true, correctionModel: "", dictationLiveTranscription: true, meetingLiveTranscription: true,
  calendarEnabled: false, calendarExcludedTitles: [], calendarAutoStart: true, calendarMeetingsOnly: true, calendarSummarize: true,
  microphoneDeviceUID: "", interactionSounds: true, snippets: [], appWritingTones: {}, cleanupEnabled: true,
  pasteIntoFocusedApp: true, saveRawAudio: false, showOverlayWhenIdle: false, theme: "system", flowbarPlacement: null,
  meetingMicrophone: true, meetingSystemAudio: true, meetingSummarize: true, shortcuts: defaultBindings,
  systemAudioDeviceId: "", calendarSources: []
};

export function normalizeSettings(settings: Partial<ParitySettings>): ParitySettings {
  return { ...defaultParitySettings, ...settings,
    shortcuts: settings.shortcuts ?? { ...defaultBindings } };
}
