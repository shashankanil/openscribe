import { describe, expect, it } from "vitest";
import { keyProviderMismatch } from "./providerKeys";

describe("keyProviderMismatch", () => {
  it("flags an OpenAI project key saved for OpenRouter", () => {
    expect(keyProviderMismatch("openRouter", "sk-proj-abc")).toBe(
      "This looks like an OpenAI key, but the provider is OpenRouter. Choose OpenAI as the provider, or paste an OpenRouter key."
    );
  });
  it("accepts keys that match the provider", () => {
    expect(keyProviderMismatch("openRouter", " sk-or-v1-abc ")).toBeNull();
    expect(keyProviderMismatch("openAI", "sk-proj-abc")).toBeNull();
    expect(keyProviderMismatch("groq", "gsk_abc")).toBeNull();
  });
  it("ignores ambiguous keys and custom endpoints", () => {
    expect(keyProviderMismatch("openRouter", "sk-abc")).toBeNull();
    expect(keyProviderMismatch("mistral", "abc123")).toBeNull();
    expect(keyProviderMismatch("custom", "sk-or-v1-abc")).toBeNull();
  });
});
