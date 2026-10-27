import { invoke } from "@tauri-apps/api/core";
export interface DictionarySettings {
  customVocabulary?: string[]; correctionRules?: { heard: string; replacement: string }[];
  speechHints?: boolean; spokenCorrections?: boolean; learnSpelledWords?: boolean; correctionModel?: string;
  languageModelProvider?: string; languageModelBaseURL?: string; languageModel?: string;
}
export interface DictionaryOutcome { text: string; learnedWords: string[] }
/** The caller persists learnedWords through save_settings; the transform never writes settings. */
export const applyDictionary = (text: string, settings: DictionarySettings) => invoke<DictionaryOutcome>("apply_dictionary", { text, settings });
