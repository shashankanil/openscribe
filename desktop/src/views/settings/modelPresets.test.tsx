import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { modelPresets, providerDefaults, providers } from "../../defaults";
import { defaultParitySettings } from "../../settings";
vi.mock("./SettingsDialog", () => ({ SettingsDialog: ({ children }: { children: React.ReactNode }) => <div>{children}</div>, settingsField: {}, settingsBox: {} }));
import { ProviderForm } from "./ProvidersSettings";

describe("economical provider selection", () => {
  it("offers both providers for speech and writing with economical defaults", () => {
    for (const id of ["openAI", "google"]) {
      expect(providers.find(provider => provider.id === id)?.speechModel).toBeTruthy();
      for (const purpose of ["speech", "writing"] as const) expect(providerDefaults(id, purpose).model).toBe(modelPresets(id, purpose)[0].id);
    }
    expect(providerDefaults("openAI", "speech").model).toBe("gpt-4o-mini-transcribe");
    expect(providerDefaults("google", "speech").model).toBe("gemini-3.5-flash-lite");
  });
  it("renders provider and model dropdowns and retains custom saved models", () => {
    const markup = renderToStaticMarkup(<ProviderForm purpose="speech" settings={{ ...defaultParitySettings, speechProvider: "openAI", speechModel: "my-existing-model" }} onUpdateSettings={vi.fn()} onSaved={vi.fn()} />);
    expect(markup).toContain('value="openAI"'); expect(markup).toContain("Google Gemini");
    expect(markup).toContain("GPT-4o mini transcribe"); expect(markup).toContain('value="custom" selected=""');
    expect(markup).toContain('value="my-existing-model"');
  });
});
