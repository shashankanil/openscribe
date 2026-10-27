import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
vi.mock("./ShortcutsSettings", () => ({ ShortcutsSettings: () => <p>Shortcut editor</p> }));
import { SettingsView, type SettingsSection } from "./SettingsView";
import { OnboardingView } from "../OnboardingView";
import { defaultParitySettings } from "../../settings";
const save = vi.fn(async () => undefined);
describe("settings parent integration", () => {
  it("renders owned settings strings without mojibake or replacement separators", () => {
    const sections: SettingsSection[] = ["general", "providers", "personalize", "calendar", "privacy", "permissions"];
    for (const section of sections) {
      const markup = renderToStaticMarkup(<SettingsView settings={defaultParitySettings} onUpdateSettings={save} selectedSection={section} />);
      expect(markup).not.toMatch(/[\uFFFD\u00C2\u00C3]|\u00E2[\u0080-\u00BF]/u);
      expect(markup).not.toMatch(/\s\?\s*(?:<strong|Shortcuts|<\/button>)/u);
    }
  });
  it("honors controlled sections and hides nested navigation", () => {
    const markup = renderToStaticMarkup(<SettingsView settings={defaultParitySettings} onUpdateSettings={save} initialSection="general" selectedSection="privacy" hideNavigation notesCount={12} meetingsCount={3} />);
    expect(markup).toContain("Notes: 12"); expect(markup).toContain("Meetings: 3"); expect(markup).not.toContain('aria-label="Settings"'); expect(markup).toContain("Recordings are sent to");
  });
  it("represents a dragged placement without resetting it and retains unavailable microphones", () => {
    const markup = renderToStaticMarkup(<SettingsView settings={{ ...defaultParitySettings, flowbarPlacement: { x: 0.2, y: 0.7 }, microphoneDeviceUID: "missing" }} onUpdateSettings={save} />);
    expect(markup).toContain('value="custom" selected=""'); expect(markup).toContain("Where I placed it"); expect(markup).toContain("Selected microphone unavailable"); expect(markup).toContain('aria-label="Appearance"');
  });
  it("shows unknown readiness honestly rather than granting permissions", () => {
    const markup = renderToStaticMarkup(<SettingsView settings={defaultParitySettings} onUpdateSettings={save} selectedSection="permissions" />);
    expect(markup).toContain("Not checked"); expect(markup).toContain("Configured sources are not a network check"); expect(markup).not.toContain("Allowed");
  });
  it("renders setup with the explicit later action", () => {
    const markup = renderToStaticMarkup(<OnboardingView settings={defaultParitySettings} onUpdateSettings={save} onComplete={vi.fn()} onLater={vi.fn()} />);
    for (const text of ["Welcome", "Connect", "Access", "Try it", "Set up later"]) expect(markup).toContain(text);
  });
});
