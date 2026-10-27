import { beforeEach, describe, expect, it, vi } from "vitest";
import type { CalendarPrompt } from "./core/calendarPolicy";
import type { MeetingRecord, VoiceNote } from "./api/parityTypes";

const mocks = vi.hoisted(() => ({
  invoke: vi.fn(), emit: vi.fn(async () => undefined), emitTo: vi.fn(async () => undefined),
  handlers: new Map<string, (event: { payload: any }) => void>(),
  stores: new Map<string, { values: Map<string, unknown>; set: ReturnType<typeof vi.fn>; save: ReturnType<typeof vi.fn>; get: ReturnType<typeof vi.fn> }>(),
  load: vi.fn()
}));
vi.mock("@tauri-apps/api/core", () => ({ invoke: mocks.invoke }));
vi.mock("@tauri-apps/api/event", () => ({ emit: mocks.emit, emitTo: mocks.emitTo, listen: vi.fn(async (name, handler) => {
  mocks.handlers.set(name, handler); return () => mocks.handlers.delete(name);
}) }));
vi.mock("@tauri-apps/api/window", () => ({ Window: { getByLabel: vi.fn(async () => ({ show: vi.fn(), setFocus: vi.fn() })) } }));
vi.mock("@tauri-apps/plugin-clipboard-manager", () => ({ readText: vi.fn(async () => ""), writeText: vi.fn(async () => undefined) }));
vi.mock("@tauri-apps/plugin-store", () => ({ load: mocks.load }));

import { cleanupInstruction } from "./defaults";
import { MainController } from "./mainController";
import { defaultParitySettings, normalizeSettings } from "./settings";
import { defaultBindings } from "./core/shortcuts";

const note: VoiceNote = { id: "NOTE", createdAt: "2026-10-19T10:00:00Z", title: "Today", rawText: "", cleanedText: "", duration: 0, isPinned: false, tags: [], source: "Dictation", captures: [] };
const meeting = (status: MeetingRecord["status"]): MeetingRecord => ({ id: "MEETING", title: "Meeting", createdAt: 1, duration: 1, status, summarizeOnStop: true, includesMicrophone: true, includesSystemAudio: true, settings: {}, segments: [], summary: null, microphoneLabel: "Mic", systemLabel: "System" });
const fire = (name: string, payload: unknown) => { const handler = mocks.handlers.get(name); if (!handler) throw new Error(`Missing listener: ${name}`); handler({ payload }); };
const calls = (command: string) => mocks.invoke.mock.calls.filter(([name]) => name === command);
const settle = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };

beforeEach(() => {
  vi.clearAllMocks(); mocks.handlers.clear(); mocks.stores.clear();
  mocks.load.mockImplementation(async (name: string) => {
    if (!mocks.stores.has(name)) {
      const values = new Map<string, unknown>();
      mocks.stores.set(name, { values, get: vi.fn(async key => values.get(key)), set: vi.fn(async (key, value) => { values.set(key, structuredClone(value)); }), save: vi.fn(async () => undefined) });
    }
    return mocks.stores.get(name);
  });
  mocks.invoke.mockImplementation(async (command: string, args: any) => {
    if (command === "load_profile") return { settings: { ...defaultParitySettings, pasteIntoFocusedApp: false }, notes: [] };
    if (command === "list_meetings" || command === "list_audio_inputs" || command === "calendar_refresh") return [];
    if (command === "stop_recording") return { path: "Recovery/test.wav", duration: 1 };
    if (command === "transcribe_recording") return { text: "raw text" };
    if (command === "apply_dictionary") return { text: "corrected text", learnedWords: [] };
    if (command === "clean_transcript") return { text: "Cleaned text." };
    if (command === "add_capture") return { ...note, captures: [args.capture], cleanedText: args.capture.text };
  });
});

describe("cleanupInstruction", () => {
  const settings = { ...defaultParitySettings, customVocabulary: [] as string[] };

  it("omits the tone instruction when strength is light", () => {
    const light = cleanupInstruction({ ...settings, cleanupStrength: "light", writingTone: "formal" });
    expect(light).not.toMatch(/Use a \w+ tone/);
    expect(light).not.toContain("formal");
    expect(cleanupInstruction({ ...settings, cleanupStrength: "clear", writingTone: "casual" })).toContain("Use a casual tone.");
    expect(cleanupInstruction({ ...settings, cleanupStrength: "concise", writingTone: "formal" })).toContain("Use a formal tone.");
  });

  it("includes the speaker's dictionary only when it has terms", () => {
    expect(cleanupInstruction({ ...settings, customVocabulary: [] })).not.toContain("speaker's dictionary");
    expect(cleanupInstruction({ ...settings, customVocabulary: [" ", ""] })).not.toContain("speaker's dictionary");
    const filled = cleanupInstruction({ ...settings, customVocabulary: ["OpenScribe", "Mahakrushi"] });
    expect(filled).toContain("The speaker's dictionary: OpenScribe, Mahakrushi.");
    expect(filled).toContain("Always spell these exactly as listed.");
    expect(filled).toContain("Leave ordinary words that merely resemble an entry alone.");
  });

  it("keeps the speaker's language and script for every strength", () => {
    for (const cleanupStrength of ["light", "clear", "concise"] as const) {
      const text = cleanupInstruction({ ...settings, cleanupStrength });
      expect(text).toContain("Keep the speaker's language and script exactly as spoken.");
      expect(text).toContain("Never translate: romanised Hindi stays romanised, Devanagari stays Devanagari, and mixed Hindi-English stays mixed.");
      expect(text).toContain("clearly misheard");
      expect(text).toContain("without inventing content");
      expect(text).toContain("Fix sentence boundaries and punctuation.");
    }
  });
});

describe("main window integration", () => {
  it("passes a finalized live transcript through dictionary and save without batch upload", async () => {
    const original = mocks.invoke.getMockImplementation()!;
    mocks.invoke.mockImplementation((command, args) => command === "stop_recording"
      ? Promise.resolve({ path: "Recovery/current.wav", duration: 2, transcript: "Live final words." }) : original(command, args));
    const app = new MainController(); await app.initialize();
    await app.intent({ action: "dictate" }); await app.intent({ action: "dictate" });
    expect(calls("stop_recording")[0][1]).toEqual({ cancel: false });
    expect(calls("transcribe_recording")).toHaveLength(0);
    expect(calls("apply_dictionary")[0][1].text).toBe("Live final words.");
    expect(calls("add_capture")[0][1].capture.rawText).toBe("Live final words.");
    expect(app.state.recoveries).toEqual([]);
  });
  it("shows only the active take's live transcript, including setup events before startup returns", async () => {
    const original = mocks.invoke.getMockImplementation()!;
    mocks.invoke.mockImplementation(async (command, args) => {
      if (command === "start_recording") {
        fire("dictation://partial", { path: "Recovery/current.wav", text: "Live words", hint: "Streaming transcription" });
        return "Recovery/current.wav";
      }
      return original(command, args);
    });
    const app = new MainController(); await app.initialize(); await app.startDictation();
    expect(app.state.currentTranscript).toBe("Live words"); expect(app.state.captureHint).toBe("Streaming transcription");
    fire("dictation://partial", { path: "Recovery/older.wav", text: "Stale words", hint: "Streaming transcription" });
    expect(app.state.currentTranscript).toBe("Live words");
    fire("dictation://partial", { path: "Recovery/current.wav", text: "", hint: "" });
    expect(app.state.captureHint).toBe(""); expect(app.state.currentTranscript).toBe("");
    await app.dictation.finish(true);
    fire("dictation://partial", { path: "Recovery/current.wav", text: "Too late", hint: "Streaming transcription" });
    expect(app.state.currentTranscript).toBe(""); expect(app.state.captureHint).toBe("");
  });
  it("acknowledges a taught correction only after settings persist, and reports save failure", async () => {
    const app = new MainController(); await app.initialize();
    fire("workspace://teach-correction", { requestId: "one", heard: "open scribe", replacement: "OpenScribe" });
    await settle();
    expect(app.state.settings.correctionRules).toContainEqual(expect.objectContaining({ heard: "open scribe", replacement: "OpenScribe" }));
    expect(mocks.emit).toHaveBeenCalledWith("workspace://correction-result", { requestId: "one" });
    const original = mocks.invoke.getMockImplementation()!;
    mocks.invoke.mockImplementation((command, args) => command === "save_settings" ? Promise.reject("Disk full") : original(command, args));
    fire("workspace://teach-correction", { requestId: "two", heard: "new", replacement: "New" }); await settle();
    expect(mocks.emit).toHaveBeenCalledWith("workspace://correction-result", { requestId: "two", error: "Disk full" });
    expect(app.state.settings.correctionRules).not.toContainEqual(expect.objectContaining({ heard: "new" }));
  });
  it("routes Flowbar settings and notice details into the workspace", async () => {
    const app = new MainController(); await app.initialize();
    await app.intent({ action: "settings", section: "shortcuts" });
    expect(app.state.navigation).toEqual({ section: "settings", settingsSection: "shortcuts" });
    app.error("Provider failed"); await app.intent({ action: "inspectNotice" });
    expect(app.state.noticeDetails).toBe(true); expect(app.state.notice).toBe("Provider failed");
  });
  it("registers all seven Windows defaults, once, and preserves explicitly unbound settings", async () => {
    expect(normalizeSettings({}).shortcuts).toEqual(defaultBindings);
    expect(normalizeSettings({ shortcuts: {} }).shortcuts).toEqual({});
    const app = new MainController(); await Promise.all([app.initialize(), app.initialize()]);
    expect(calls("register_shortcuts")).toEqual([["register_shortcuts", { bindings: defaultBindings }]]);
    expect(Object.keys(app.state.settings.shortcuts)).toHaveLength(7);
  });

  it("keeps the other shortcuts when another app holds one, and reports it as macOS does", async () => {
    const original = mocks.invoke.getMockImplementation()!;
    mocks.invoke.mockImplementation(async (command: string, args: any) => command === "register_shortcuts" ? ["dictate"] : original(command, args));
    const app = new MainController(); await app.initialize();
    expect(app.state.shortcutFailures).toEqual(["dictate"]);
    expect(app.state.notice).toContain("Dictate (Ctrl Alt Space)");
    mocks.invoke.mockImplementation(original);
    await app.updateSettings({ ...app.state.settings, shortcuts: { ...app.state.settings.shortcuts, dictate: { accelerator: "Ctrl+Shift+F9", display: "Ctrl Shift F9" } } });
    expect(app.state.shortcutFailures).toEqual([]);
  });

  it("claims Escape only while recording and cancels the dictation with it", async () => {
    const app = new MainController(); await app.initialize();
    await app.startDictation(); await settle();
    expect(calls("set_escape_active").map(call => call[1])).toEqual([{ active: true }]);
    fire("shortcut://escape", null); await settle();
    expect(app.dictation.phase).toBe("idle");
    expect(calls("set_escape_active").map(call => call[1])).toEqual([{ active: true }, { active: false }]);
    expect(calls("transcribe_recording")).toHaveLength(0);
    expect(calls("stop_recording")[0][1]).toEqual({ cancel: true });
    expect(calls("add_capture")).toHaveLength(0);
  });

  it("finishes a hold released during microphone startup through the same controller", async () => {
    let started!: () => void;
    const original = mocks.invoke.getMockImplementation()!;
    mocks.invoke.mockImplementation((command, args) => command === "start_recording" ? new Promise<void>(resolve => { started = resolve; }) : original(command, args));
    const app = new MainController(); await app.initialize();
    fire("shortcut://action", { action: "holdToTalk", state: "pressed" }); await settle();
    expect(app.state.phase).toBe("starting");
    expect(calls("set_dictation_busy").at(-1)).toEqual(["set_dictation_busy", { busy: true }]);
    fire("shortcut://action", { action: "holdToTalk", state: "released" });
    started(); await vi.waitFor(() => expect(app.state.phase).toBe("idle")); await settle();
    expect(calls("start_recording")).toHaveLength(1); expect(calls("stop_recording")).toHaveLength(1);
    expect(calls("add_capture")).toHaveLength(1);
    expect(app.state.phase).toBe("idle");
    expect(calls("set_dictation_busy").at(-1)).toEqual(["set_dictation_busy", { busy: false }]);
  });

  it("runs dictionary, learns vocabulary, cleans, saves, then deletes audio; backend builds hints", async () => {
    const original = mocks.invoke.getMockImplementation()!;
    mocks.invoke.mockImplementation((command, args) => command === "apply_dictionary" ? Promise.resolve({ text: "corrected text", learnedWords: ["OpenScribe"] }) : original(command, args));
    const app = new MainController(); await app.initialize(); await app.intent({ action: "dictate" }); await app.intent({ action: "dictate" });
    expect(calls("transcribe_recording")[0][1]).toEqual({ path: "Recovery/test.wav", config: { provider: "openRouter", baseUrl: "https://openrouter.ai/api/v1", model: "mistralai/voxtral-mini-transcribe", credentialAccount: "speech:openRouter:https://openrouter.ai/api/v1" } });
    expect(calls("clean_transcript")[0][1].text).toBe("corrected text");
    expect(calls("clean_transcript")[0][1].instruction).toBe(cleanupInstruction({ cleanupStrength: "clear", writingTone: "natural", customVocabulary: [] }));
    expect(app.state.settings.customVocabulary).toContain("OpenScribe");
    expect(app.state.notes[0].captures?.[0].text).toBe("Cleaned text.");
    const commands = mocks.invoke.mock.calls.map(([name]) => name);
    expect(commands.indexOf("add_capture")).toBeLessThan(commands.indexOf("delete_recording"));
    expect(mocks.stores.get("dictation-recovery.json")!.values.get("jobs")).toEqual([]);
    expect(mocks.stores.get("openscribe.json")!.set).not.toHaveBeenCalled();
    expect(mocks.stores.get("openscribe.json")!.save).not.toHaveBeenCalled();
  });

  it("retains failed saves for real retry, reuses capture ID, and never deletes unsaved audio", async () => {
    const original = mocks.invoke.getMockImplementation()!; let fail = true;
    mocks.invoke.mockImplementation((command, args) => command === "add_capture" && fail ? Promise.reject("Disk full") : original(command, args));
    const app = new MainController(); await app.initialize(); await app.intent({ action: "dictate" }); await app.intent({ action: "dictate" });
    expect(app.state.recoveries).toHaveLength(1); expect(app.state.notice).toBe("Disk full");
    expect(calls("delete_recording")).toHaveLength(0);
    const id = app.state.recoveries[0].id;
    fail = false; await app.dictation.retry();
    expect(calls("add_capture").map(call => call[1].capture.id)).toEqual([id, id]);
    expect(calls("transcribe_recording")).toHaveLength(1); expect(app.state.recoveries).toHaveLength(0);
  });

  it("saves the transcript when cleanup fails, as on macOS", async () => {
    const original = mocks.invoke.getMockImplementation()!;
    mocks.invoke.mockImplementation((command, args) => command === "clean_transcript" ? Promise.reject("Add your writing provider key in Settings.") : original(command, args));
    const app = new MainController(); await app.initialize(); await app.intent({ action: "dictate" }); await app.intent({ action: "dictate" });
    expect(calls("add_capture")[0][1].capture.text).toBe("corrected text");
    expect(app.state.recoveries).toHaveLength(0);
    expect(app.state.notice).toBe("Transcript saved; cleanup unavailable: Add your writing provider key in Settings.");
  });

  it("expands snippets without rewriting their content", async () => {
    const app = new MainController(); await app.initialize();
    await app.updateSettings({ ...app.state.settings, snippets: [{ id: "S", trigger: "corrected text", replacement: "Exact signature\nSecond line" }] });
    await app.intent({ action: "dictate" }); await app.intent({ action: "dictate" });
    expect(calls("clean_transcript")).toHaveLength(0);
    expect(calls("add_capture")[0][1].capture.text).toBe("Exact signature\nSecond line");
  });

  it("imports old dictation jobs once without changing the legacy store", async () => {
    const legacy = await mocks.load("openscribe.json");
    legacy.values.set("state", { recoveries: [{ id: "old-job", path: "Recovery/old.wav", duration: 2, createdAt: "2026-10-19T00:00:00Z", kind: "dictation" }, { id: "MEETING-JOB", path: "old-meeting.wav", kind: "meeting" }] });
    const first = new MainController(); await first.initialize();
    expect(first.state.recoveries.map(job => job.id)).toEqual(["OLD-JOB"]);
    await first.dictation.discard();
    const restarted = new MainController(); await restarted.initialize();
    expect(restarted.state.recoveries).toEqual([]);
    expect(legacy.set).not.toHaveBeenCalled(); expect(legacy.save).not.toHaveBeenCalled();
    expect(legacy.values.get("state").recoveries).toHaveLength(2);
  });

  it("blocks capture if recovery cannot become durable", async () => {
    const store = await mocks.load("dictation-recovery.json"); store.save.mockRejectedValue(new Error("Recovery write denied"));
    const app = new MainController(); await app.initialize(); await app.intent({ action: "dictate" });
    expect(calls("start_recording")).toHaveLength(0);
    expect(app.state.notice).toContain("unavailable");
  });

  it("rolls shortcut registration back when settings fail to save", async () => {
    const app = new MainController(); await app.initialize();
    const original = mocks.invoke.getMockImplementation()!;
    mocks.invoke.mockImplementation((command, args) => command === "save_settings" ? Promise.reject("Settings write denied") : original(command, args));
    await expect(app.updateSettings({ ...app.state.settings, shortcuts: {} })).rejects.toBe("Settings write denied");
    expect(app.state.settings.shortcuts).toEqual(defaultBindings);
    expect(calls("register_shortcuts").slice(-2).map(call => call[1])).toEqual([{ bindings: {} }, { bindings: defaultBindings }]);
  });

  it("uses native calendar occurrence IDs and decisions without starting or stopping twice", async () => {
    const app = new MainController(); await app.initialize();
    const prompt: CalendarPrompt = { event: { id: "real-occurrence", title: "Calendar", start: "2026-10-19T10:00:00Z", end: "2026-10-19T11:00:00Z", calendarID: "C", calendarName: "Work", hasAttendees: true, excluded: false, isAllDay: false }, kind: "start", deadline: "2026-10-19T10:01:00Z", automatic: true, message: "Record?" };
    fire("calendar://prompt-start", prompt); await app.decide(prompt, "start");
    fire("calendar://prompt-end", { ...prompt, kind: "end" }); await app.decide({ ...prompt, kind: "end" }, "extend");
    expect(calls("calendar_decision").map(call => call[1])).toEqual([{ occurrenceId: "real-occurrence", decision: "start" }, { occurrenceId: "real-occurrence", decision: "extend" }]);
    expect(calls("start_meeting")).toHaveLength(0); expect(calls("finish_meeting")).toHaveLength(0);
    fire("calendar://prompt-start", prompt); fire("calendar://prompt-closed", { occurrenceId: prompt.event.id, kind: "start" });
    expect(app.state.startPrompt).toBeNull();
  });

  it("reloads persisted screenshots and OCR instead of appending captures twice", async () => {
    const app = new MainController(); await app.initialize();
    const initial = calls("load_profile").length;
    fire("capture://added", { id: "C" }); await settle();
    fire("capture://ocr", { captureId: "C", noteId: "N" }); await settle();
    expect(calls("load_profile").length).toBe(initial + 2);
    expect(calls("add_capture")).toHaveLength(0);
  });

  it("uses current meeting state and surfaces app/calendar/capture errors", async () => {
    const app = new MainController(); await app.initialize();
    fire("meeting://changed", meeting("recording")); expect(app.activeMeeting?.id).toBe("MEETING");
    fire("meeting://changed", meeting("ready")); expect(app.activeMeeting).toBeNull();
    for (const name of ["app://error", "capture://error", "calendar://error"]) { fire(name, name); expect(app.state.notice).toBe(name); }
  });

  it("persists note deletion and refreshes actual remaining notes on a partial failure", async () => {
    const app = new MainController(); await app.initialize();
    app.setNotes([{ ...note, id: "A" }, { ...note, id: "B" }]);
    const original = mocks.invoke.getMockImplementation()!;
    mocks.invoke.mockImplementation((command, args) => {
      if (command === "delete_note" && args.id === "B") return Promise.reject("Delete denied");
      if (command === "load_profile") return Promise.resolve({ settings: defaultParitySettings, notes: [{ ...note, id: "B" }] });
      return original(command, args);
    });
    await expect(app.clearNotes()).rejects.toBe("Delete denied");
    expect(calls("delete_note").map(call => call[1])).toEqual([{ id: "A" }, { id: "B" }]);
    expect(app.state.notes.map(note => note.id)).toEqual(["B"]);
  });
});
