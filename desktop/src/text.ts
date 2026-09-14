import type { Correction, Snippet } from "./types";

const normalize = (value: string) => value.trim().replace(/^[\p{P}\s]+|[\p{P}\s]+$/gu, "").replace(/\s+/g, " ").toLocaleLowerCase();

export function expandSnippet(text: string, snippets: Snippet[]) {
  const key = normalize(text);
  return snippets.find((snippet) => normalize(snippet.trigger) === key && snippet.replacement.trim())?.replacement;
}

export function applyCorrections(text: string, rules: Correction[]) {
  const usable = rules.filter((rule) => rule.heard.trim() && rule.replacement.trim()).sort((a, b) => b.heard.length - a.heard.length);
  if (!usable.length) return text;
  const escaped = usable.map((rule) => rule.heard.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
  const regex = new RegExp(`(?<![\\p{L}\\p{N}_])(?:${escaped.join("|")})(?![\\p{L}\\p{N}_])`, "giu");
  return text.replace(regex, (match) => usable.find((rule) => rule.heard.toLocaleLowerCase() === match.toLocaleLowerCase())?.replacement ?? match);
}

export function noteTitle(text: string) {
  const first = text.trim().split(/[.!?\n]/)[0]?.trim() || "Untitled note";
  return first.length > 58 ? `${first.slice(0, 55)}…` : first;
}
