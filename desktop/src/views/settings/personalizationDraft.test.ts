import { describe, expect, it } from "vitest";
import type { ParitySettings } from "../../api/parityTypes";
import { applyPersonalizationDraft, normalizeTrigger, vocabularyWords } from "./personalizationDraft";
import { canPractice, type CaptureReadiness } from "./settingsSupport";
const settings = { customVocabulary: [], snippets: [{ id: "OLD", trigger: "My signature", replacement: "Exact\ntext" }], correctionRules: [{ id: "RULE", heard: "foo", replacement: "bar" }], appWritingTones: { "old.exe": "natural" } } as unknown as ParitySettings;
describe("personalization editor validation", () => {
  it("deduplicates vocabulary preserving display spelling", () => { expect(vocabularyWords(" OpenScribe, openscribe\n Alpha , ,Beta")).toEqual(["OpenScribe", "Alpha", "Beta"]); });
  it("matches snippet whitespace, case and edge punctuation like Swift", () => { expect(normalizeTrigger(" My   SIGNATURE! ")).toBe("my signature"); expect(() => applyPersonalizationDraft(settings, { kind: "snippet", trigger: "my signature!", replacement: "new", tone: "natural" })).toThrow("already uses"); });
  it("edits IDs in place and preserves internal newlines", () => { const next = applyPersonalizationDraft(settings, { kind: "snippet", original: "OLD", trigger: "signature", replacement: " Exact\ntext ", tone: "natural" }); expect(next.snippets).toEqual([{ id: "OLD", trigger: "signature", replacement: "Exact\ntext" }]); expect(settings.snippets[0].trigger).toBe("My signature"); });
  it("replaces same-spelling corrections without duplication", () => { const next = applyPersonalizationDraft(settings, { kind: "correction", trigger: "FOO", replacement: "baz", tone: "natural" }, () => "NEW"); expect(next.correctionRules).toEqual([{ id: "NEW", heard: "FOO", replacement: "baz" }]); });
  it("renames app identities to lowercase without mutating the source", () => { const next = applyPersonalizationDraft(settings, { kind: "appStyle", original: "old.exe", trigger: "C:\\Apps\\New.EXE", replacement: "", tone: "formal" }); expect(next.appWritingTones).toEqual({ "c:\\apps\\new.exe": "formal" }); expect(settings.appWritingTones).toEqual({ "old.exe": "natural" }); });
  it("rejects missing fields and punctuation-only snippets", () => { expect(() => applyPersonalizationDraft(settings, { kind: "correction", trigger: "foo", replacement: " ", tone: "natural" })).toThrow(); expect(() => applyPersonalizationDraft(settings, { kind: "snippet", trigger: "!!!", replacement: "text", tone: "natural" })).toThrow(); });
});
describe("setup readiness", () => {
  const readiness: CaptureReadiness = { microphone: { ready: true, detail: "" }, paste: { ready: false, detail: "" }, systemAudio: { ready: false, detail: "" }, calendar: { ready: false, detail: "" } };
  it("requires a credential and real microphone result", () => { expect(canPractice(null, true, false)).toBe(false); expect(canPractice(readiness, false, false)).toBe(false); expect(canPractice({ ...readiness, microphone: { ready: false, detail: "" } }, true, false)).toBe(false); });
  it("lets Notes-only dictation work without optional access", () => { expect(canPractice(readiness, true, false)).toBe(true); expect(canPractice(readiness, true, true)).toBe(false); });
});
