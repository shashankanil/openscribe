import { beforeEach, describe, expect, it, vi } from "vitest";
vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn() }));
import { invoke } from "@tauri-apps/api/core";
import { connectionValidation, settingsNative, speechHintDetail } from "./settingsSupport";
beforeEach(() => vi.mocked(invoke).mockReset());
describe("connection editor validation matches ProviderConnectionDraft", () => {
  it("accepts HTTP local services and HTTPS provider endpoints", () => { expect(connectionValidation(" http://localhost:8080/v1 ", " local-model ")).toBeNull(); expect(connectionValidation("https://api.openai.com/v1", "model")).toBeNull(); });
  it("rejects empty models, placeholder hosts and embedded credentials", () => { for (const [url, model] of [["https://api.openai.com/v1", " "], ["https://example.com/v1", "model"], ["https://user:password@host.test/v1", "model"], ["file:///tmp/api", "model"], ["invalid", "model"]]) expect(connectionValidation(url, model)).not.toBeNull(); });
});
describe("Windows settings invoke contracts", () => {
  it("uses exact launch-at-login argument names and returns the actual state", async () => { vi.mocked(invoke).mockResolvedValueOnce(true).mockResolvedValueOnce(undefined); expect(await settingsNative.getLaunchAtLogin()).toBe(true); await settingsNative.setLaunchAtLogin(false); expect(invoke).toHaveBeenNthCalledWith(1, "get_launch_at_login"); expect(invoke).toHaveBeenNthCalledWith(2, "set_launch_at_login", { enabled: false }); });
  it("keeps readiness and source-app results from native", async () => { const result = { microphone: { ready: false, detail: "Device unavailable" } }; vi.mocked(invoke).mockResolvedValueOnce(result).mockResolvedValueOnce([{ id: "c:\\app.exe", name: "App", path: "C:\\app.exe" }]); expect(await settingsNative.captureReadiness()).toBe(result); expect((await settingsNative.listSourceApps())[0].id).toBe("c:\\app.exe"); expect(invoke).toHaveBeenNthCalledWith(1, "capture_readiness"); expect(invoke).toHaveBeenNthCalledWith(2, "list_source_apps"); });
  it("opens only the requested Windows section and propagates native errors", async () => { vi.mocked(invoke).mockRejectedValueOnce(new Error("Settings unavailable")); await expect(settingsNative.openWindowsSettings("sound")).rejects.toThrow("Settings unavailable"); expect(invoke).toHaveBeenCalledWith("open_windows_settings", { section: "sound" }); });
});
describe("speech-hint availability follows the Swift support switch", () => {
  it("does not claim direct hints for unsupported OpenRouter models", () => { expect(speechHintDetail("openRouter", "other/transcriber")).toBeNull(); expect(speechHintDetail("openRouter", "mistralai/voxtral")).toContain("context biasing"); expect(speechHintDetail("openRouter", "openai/whisper")).toContain("glossary"); });
  it("distinguishes Deepgram key terms from legacy keywords", () => { expect(speechHintDetail("deepgram", "nova-3")).toContain("key terms"); expect(speechHintDetail("deepgram", "nova-2")).toContain("keywords"); expect(speechHintDetail("custom", "model")).toContain("if your endpoint supports"); });
});
