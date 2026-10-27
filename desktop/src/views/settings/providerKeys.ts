import { providers } from "../../defaults";

// Only prefixes that unambiguously identify one provider. Bare "sk-" keys are left alone.
const keyPrefixes: [prefix: string, provider: string][] = [
  ["sk-or-", "openRouter"],
  ["sk-ant-", "anthropic"],
  ["sk-proj-", "openAI"],
  ["sk-svcacct-", "openAI"],
  ["sk-admin-", "openAI"],
  ["gsk_", "groq"],
  ["AIza", "google"]
];

const title = (id: string) => providers.find(choice => choice.id === id)?.title ?? id;
const article = (word: string) => (/^[aeiou]/i.test(word) ? "an" : "a");

/** A message when a pasted key clearly belongs to a different provider than the one selected. */
export function keyProviderMismatch(provider: string, key: string): string | null {
  if (provider === "custom") return null;
  const owner = keyPrefixes.find(([prefix]) => key.trim().startsWith(prefix))?.[1];
  if (!owner || owner === provider) return null;
  const [ownerTitle, providerTitle] = [title(owner), title(provider)];
  return `This looks like ${article(ownerTitle)} ${ownerTitle} key, but the provider is ${providerTitle}. Choose ${ownerTitle} as the provider, or paste ${article(providerTitle)} ${providerTitle} key.`;
}
