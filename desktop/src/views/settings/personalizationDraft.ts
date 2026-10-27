import type { ParitySettings } from "../../api/parityTypes";
export interface PersonalizationDraft { kind: "vocabulary" | "correction" | "snippet" | "appStyle"; original?: string; trigger: string; replacement: string; tone: string }
export const normalizeTrigger = (value: string) => value.trim().replace(/^[\p{P}\s]+|[\p{P}\s]+$/gu, "").replace(/\s+/g, " ").toLowerCase();
export const vocabularyWords = (value: string) => { const seen = new Set<string>(); return value.split(/[,\n]/).map(word => word.trim()).filter(word => { if (!word || seen.has(word.toLowerCase())) return false; seen.add(word.toLowerCase()); return true; }); };
export function applyPersonalizationDraft(settings: ParitySettings, draft: PersonalizationDraft, newID: () => string = () => crypto.randomUUID().toUpperCase()): ParitySettings {
  const trigger = draft.trigger.trim(), replacement = draft.replacement.trim();
  if (draft.kind === "vocabulary") return { ...settings, customVocabulary: vocabularyWords(draft.replacement) };
  if (!trigger || (draft.kind !== "appStyle" && !replacement)) throw new Error("Complete both fields before saving.");
  if (draft.kind === "snippet") {
    if (!normalizeTrigger(trigger)) throw new Error("Use a trigger with words, not only punctuation.");
    if (settings.snippets.some(item => item.id !== draft.original && normalizeTrigger(item.trigger) === normalizeTrigger(trigger))) throw new Error("A snippet already uses that trigger.");
    return { ...settings, snippets: [...settings.snippets.filter(item => item.id !== draft.original), { id: draft.original ?? newID(), trigger, replacement }] };
  }
  if (draft.kind === "correction") return { ...settings, correctionRules: [...settings.correctionRules.filter(item => item.id !== draft.original && item.heard.toLowerCase() !== trigger.toLowerCase()), { id: draft.original ?? newID(), heard: trigger, replacement }] };
  if (!["natural", "casual", "formal"].includes(draft.tone)) throw new Error("Choose a writing tone.");
  const identity = trigger.toLowerCase();
  if (!identity.endsWith(".exe") && !identity.startsWith("aumid:")) throw new Error("Choose an executable or enter an executable identity ending in .exe.");
  const appWritingTones = { ...settings.appWritingTones };
  if (draft.original) delete appWritingTones[draft.original];
  appWritingTones[identity] = draft.tone;
  return { ...settings, appWritingTones };
}
