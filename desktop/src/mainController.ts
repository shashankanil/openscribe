import { emit, listen } from "@tauri-apps/api/event";
import { Window } from "@tauri-apps/api/window";
import * as api from "./api/parity";
import type { CalendarEvent, MeetingRecord, ParitySettings, VoiceNote } from "./api/parityTypes";
import type { CalendarPrompt } from "./core/calendarPolicy";
import { pasteLastText } from "./core/dailyNotes";
import { shortcutActions, ShortcutInterpreter, shortcutTitles, type ShortcutAction, validateBindings } from "./core/shortcuts";
import { DictationController, type DictationJob, type DictationPhase } from "./dictation";
import { CaptureSounds } from "./captureSounds";
import { cleanupInstruction } from "./defaults";
import { ListenerScope } from "./listeners";
import { native } from "./native";
import { stopLiveRecording, type DictationPartial } from "./liveDictation";
import { DictationRecovery } from "./recovery";
import { defaultParitySettings, normalizeSettings } from "./settings";
import { expandSnippet } from "./text";
import type { AudioInput } from "./types";
import type { WorkspaceIntent, WorkspaceStatus } from "./workspaceEvents";

export interface MainState {
  settings: ParitySettings; notes: VoiceNote[]; meetings: MeetingRecord[]; recoveries: DictationJob[];
  calendarEvents: CalendarEvent[]; inputs: AudioInput[]; phase: DictationPhase; loaded: boolean;
  storageError: string | null; notice: string | null; startPrompt: CalendarPrompt | null; endPrompt: CalendarPrompt | null;
  navigation?: { section: "notes" | "meetings" | "settings"; meetingId?: string; noteId?: string; settingsSection?: import("./views/settings/SettingsView").SettingsSection };
  noticeDetails?: boolean;
  /** Actions whose shortcut another app holds, as macOS reports them. */
  shortcutFailures: ShortcutAction[];
  currentTranscript?: string;
  captureHint?: string;
}

/** One instance lives in main, including while its window is hidden. */
export class MainController {
  state: MainState = { settings: defaultParitySettings, notes: [], meetings: [], recoveries: [], calendarEvents: [], inputs: [],
    phase: "idle", loaded: false, storageError: null, notice: null, startPrompt: null, endPrompt: null, shortcutFailures: [] };
  private observers = new Set<() => void>();
  private initialization?: Promise<void>;
  private scope = new ListenerScope();
  private interpreter = new ShortcutInterpreter();
  private recovery = new DictationRecovery();
  private ready = false;
  private meetingTransition = false;
  private sounds = new CaptureSounds();
  private cuedMeeting: string | null = null;
  private busyUpdate: Promise<unknown> = Promise.resolve();
  private settingsWrites: Promise<unknown> = Promise.resolve();
  private notesRefresh = 0;
  private escapeActive = false;
  private dictationPath?: string;
  private pendingLive = new Map<string, DictationPartial>();
  readonly dictation = new DictationController({
    settings: () => this.state.settings,
    sourceApp: native.foregroundApp,
    cancelProcessing: native.cancelDictationWork,
    success: message => this.confirm(message),
    cue: cue => { if (this.state.settings.interactionSounds) this.sounds.play(cue); },
    start: async device => {
      await this.busyUpdate;
      const path = await native.startRecording(device);
      this.dictationPath = path;
      const partial = this.pendingLive.get(path);
      this.pendingLive.clear();
      if (partial) this.patch({ currentTranscript: partial.text, captureHint: partial.hint });
      return path;
    },
    stop: stopLiveRecording,
    // Native builds the complete provider hints from the persisted profile.
    transcribe: async (path, settings) => (await native.transcribe(path, settings)).text,
    transform: async (text, settings) => {
      const result = await api.applyDictionary(text, settings);
      if (result.learnedWords.length) {
        await this.updateSettings({ ...this.state.settings, customVocabulary: [...new Set([...this.state.settings.customVocabulary, ...result.learnedWords])] });
      }
      const snippet = expandSnippet(result.text, settings.snippets);
      if (snippet) return snippet;
      if (!settings.cleanupEnabled) return result.text;
      let cleaned: string;
      try {
        cleaned = (await native.clean(result.text, settings, cleanupInstruction(settings))).text;
      } catch (error) {
        if (String(error).toLowerCase().includes("cancelled")) throw error;
        // As on macOS, a cleanup failure keeps the transcript instead of holding the dictation back.
        this.error(`Transcript saved; cleanup unavailable: ${String(error)}`);
        return result.text;
      }
      if (!cleaned.trim()) return result.text;
      return expandSnippet(cleaned, settings.snippets) ?? cleaned;
    },
    save: async capture => {
      const saved = await api.addCapture(capture);
      this.patch({ notes: [saved, ...this.state.notes.filter(note => note.id !== saved.id)] });
    },
    persist: jobs => this.recovery.persist(jobs), removeAudio: native.deleteRecording, paste: native.paste,
    changed: (phase, recoveries) => {
      if (phase === "starting" || phase === "idle") {
        this.dictationPath = undefined; this.pendingLive.clear();
        this.patch({ currentTranscript: "", captureHint: "" });
      }
      this.patch({ phase, recoveries });
      // Serialize transitions so an older idle update cannot overtake a new start.
      this.busyUpdate = this.busyUpdate.catch(() => undefined).then(() => native.setDictationBusy(phase !== "idle"));
      void this.busyUpdate.catch(this.error);
      const escape = phase !== "idle";
      if (escape !== this.escapeActive) { this.escapeActive = escape; void api.setEscapeActive(escape).catch(this.error); }
    },
    error: error => this.error(error)
  });
  subscribe = (observer: () => void) => { this.observers.add(observer); return () => { this.observers.delete(observer); }; };
  snapshot = () => this.state;
  get activeMeeting() { return this.state.meetings.find(record => record.status === "recording" || record.status === "paused") ?? null; }
  private patch(update: Partial<MainState>) {
    this.state = { ...this.state, ...update }; this.observers.forEach(observer => observer());
    void this.publish().catch(console.error);
  }
  private publish = () => emit("workspace://status", {
    phase: this.state.phase, settings: this.state.settings, activeMeeting: this.activeMeeting,
    processingMeeting: this.meetingTransition || this.state.meetings.some(m => m.status === "transcribing" || m.status === "summarizing"), notice: this.state.notice,
    currentTranscript: this.state.currentTranscript, captureHint: this.state.captureHint
  } satisfies WorkspaceStatus);
  /** As on macOS, a meeting plays the start cue once when it begins recording, not on resume. */
  private cueMeeting(record: MeetingRecord) {
    if (record.status !== "recording" || record.id === this.cuedMeeting) return;
    this.cuedMeeting = record.id;
    if (this.state.settings.interactionSounds) this.sounds.play("start");
  }
  error = (error: unknown) => { this.patch({ notice: String(error) }); };
  clearNotice = () => this.patch({ notice: null });
  closeNoticeDetails = () => this.patch({ noticeDetails: false });
  private confirm(message: string) { void emit("workspace://confirmation", { message, id: crypto.randomUUID() }).catch(console.error); }
  clearStorageError = () => this.patch({ storageError: null });
  initialize() {
    return this.initialization ??= this.initializeOnce();
  }
  private async initializeOnce() {
    const add = (promise: Promise<() => void>) => this.scope.add(promise, this.error);
    add(api.parityEvents.onMeetingChanged(record => {
      this.cueMeeting(record);
      this.patch({ meetings: [record, ...this.state.meetings.filter(m => m.id !== record.id)] });
      void this.refreshNotes().catch(this.error);
    }));
    add(api.parityEvents.onCaptureOcr(() => { void this.refreshNotes().catch(this.error); }));
    add(listen("capture://added", () => { void this.refreshNotes().catch(this.error); }));
    add(api.parityEvents.onCalendarPromptStart(startPrompt => this.patch({ startPrompt })));
    add(api.parityEvents.onCalendarPromptEnd(endPrompt => this.patch({ endPrompt })));
    add(api.parityEvents.onCalendarPromptClosed(({ occurrenceId, kind }) => {
      const prompt = kind === "start" ? this.state.startPrompt : this.state.endPrompt;
      if (prompt?.event.id === occurrenceId) this.patch(kind === "start" ? { startPrompt: null } : { endPrompt: null });
    }));
    add(api.parityEvents.onCalendarError(this.error));
    add(listen<string>("app://error", event => this.error(event.payload)));
    add(listen<string>("capture://error", event => this.error(event.payload)));
    add(listen<DictationPartial>("dictation://partial", ({ payload }) => {
      if (this.dictation.phase === "starting") {
        // Setup can emit before start_recording returns its path. Never show a previous take.
        if (this.pendingLive.size >= 8) this.pendingLive.clear();
        this.pendingLive.set(payload.path, payload);
      } else if (payload.path === this.dictationPath && (this.dictation.phase === "recording" || this.dictation.phase === "transcribing")) {
        this.patch({ currentTranscript: payload.text, captureHint: payload.hint });
      }
    }));
    add(api.parityEvents.onShortcutAction(({ action, state }) => {
      if (!this.ready || !shortcutActions.includes(action as ShortcutAction)) return;
      const phase = this.dictation.phase;
      for (const intent of this.interpreter.handle(action as ShortcutAction, state, performance.now(), phase === "starting" || phase === "recording", phase !== "idle" || !!this.activeMeeting || this.meetingTransition)) {
        if (intent === "startDictation") void this.startDictation();
        else if (intent === "finishDictation") void this.dictation.finish();
        else if (intent === "cancelDictation") void this.dictation.finish(true);
        else if (intent.startsWith("screenshot")) void this.intent({ action: "screenshot", kind: intent.slice(10).toLowerCase() as "area" | "window" | "screen" });
        else void this.intent({ action: intent as "meeting" | "pasteLast" });
      }
    }));
    add(api.parityEvents.onShortcutEscape(() => {
      if (this.dictation.phase !== "idle") void this.dictation.finish(true);
    }));
    add(listen<WorkspaceIntent>("workspace://intent", event => { void this.intent(event.payload).catch(this.error); }));
    add(listen("workspace://request-state", () => { void this.publish().catch(this.error); }));
    add(listen<string>("workspace://error", event => this.error(event.payload)));
    add(listen("workspace://refresh-notes", () => { void this.refreshNotes().catch(this.error); }));
    add(listen("workspace://refresh-meetings", () => { void this.refreshMeetings().catch(this.error); }));
    add(listen<{ requestId: string; heard: string; replacement: string }>("workspace://teach-correction", event => {
      const { requestId, heard, replacement } = event.payload;
      void (async () => {
        try {
          if (!heard.trim() || !replacement.trim()) throw new Error("Enter both phrases.");
          await this.updateSettings({ ...this.state.settings, correctionRules: [...this.state.settings.correctionRules.filter(rule => rule.heard.toLowerCase() !== heard.trim().toLowerCase()), { id: crypto.randomUUID(), heard: heard.trim(), replacement: replacement.trim() }] });
          await emit("workspace://correction-result", { requestId });
          this.confirm("Correction saved");
        } catch (error) { await emit("workspace://correction-result", { requestId, error: String(error) }); this.error(error); }
      })();
    }));
    add(listen<{ meetingId: string; createdAt: number }>("workspace://open-day", event => {
      const { meetingId, createdAt } = event.payload;
      const day = new Date((createdAt + 978307200) * 1000).toLocaleDateString();
      const note = this.state.notes.find(note => note.captures?.some(capture => capture.meetingID === meetingId))
        ?? this.state.notes.find(note => note.captures != null && new Date(note.createdAt).toLocaleDateString() === day);
      const date = new Date((createdAt + 978307200) * 1000);
      const dateKey = `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
      this.patch({ navigation: { section: "notes", noteId: note?.id ?? `day:${dateKey}` } });
    }));
    // Load all durable state before capture actions become available.
    const results = await Promise.allSettled([
      api.loadProfile().then(profile => this.patch({ settings: normalizeSettings(profile.settings), notes: profile.notes, storageError: profile.storageError ?? null })),
      api.listMeetings().then(meetings => {
        // A meeting already recording at launch has had its cue.
        this.cuedMeeting ??= meetings.find(record => record.status === "recording" || record.status === "paused")?.id ?? null;
        this.patch({ meetings });
      }),
      native.listInputs().then(inputs => this.patch({ inputs })),
      this.recovery.load().then(recoveries => { this.dictation.jobs = recoveries; this.patch({ recoveries }); })
    ]);
    results.forEach(result => { if (result.status === "rejected") this.error(result.reason); });
    this.ready = results[0].status === "fulfilled" && results[3].status === "fulfilled";
    if (this.ready) {
      try {
        this.setShortcutFailures(await api.registerShortcuts(this.state.settings.shortcuts), true);
        await native.setDictationBusy(false);
      } catch (error) { this.error(error); }
    }
    this.patch({ loaded: true });
    void this.refreshCalendar().catch(this.error);
  }
  async refreshNotes() {
    const request = ++this.notesRefresh;
    const profile = await api.loadProfile();
    if (request === this.notesRefresh) this.patch({ notes: profile.notes, storageError: profile.storageError ?? null });
  }
  async refreshMeetings() { this.patch({ meetings: await api.listMeetings() }); await this.refreshNotes(); }
  async refreshCalendar() { this.patch({ calendarEvents: await api.calendarRefresh() }); }
  updateSettings = (settings: ParitySettings): Promise<void> => {
    const write = this.settingsWrites.catch(() => undefined).then(async () => {
      validateBindings(settings.shortcuts);
      const previous = this.state.settings;
      const bindingsChanged = JSON.stringify(previous.shortcuts) !== JSON.stringify(settings.shortcuts);
      const failures = bindingsChanged ? await api.registerShortcuts(settings.shortcuts) : null;
      try { await api.saveSettings(settings); }
      catch (error) {
        if (bindingsChanged) await api.registerShortcuts(previous.shortcuts).then(restored => this.setShortcutFailures(restored)).catch(this.error);
        throw error;
      }
      if (failures) this.setShortcutFailures(failures);
      this.patch({ settings });
      if (previous.calendarEnabled !== settings.calendarEnabled || JSON.stringify(previous.calendarSources) !== JSON.stringify(settings.calendarSources)) void this.refreshCalendar().catch(this.error);
    });
    this.settingsWrites = write;
    return write;
  };
  /** Pauses global shortcuts while Settings records a new one. */
  suspendShortcuts = async (suspended: boolean) => { this.setShortcutFailures(await api.suspendShortcuts(suspended)); };
  private setShortcutFailures(failures: string[], announce = false) {
    const shortcutFailures = shortcutActions.filter(action => failures.includes(action));
    if (JSON.stringify(shortcutFailures) !== JSON.stringify(this.state.shortcutFailures)) this.patch({ shortcutFailures });
    if (announce && shortcutFailures.length) {
      const keys = shortcutFailures.map(action => `${shortcutTitles[action]} (${this.state.settings.shortcuts[action]?.display ?? "?"})`).join(", ");
      this.error(`Some shortcuts aren’t active because another app is using their keys: ${keys}. Choose different keys in Settings → Shortcuts.`);
    }
  }
  setNotes = (notes: VoiceNote[]) => this.patch({ notes });
  setMeetings = (_meetings: MeetingRecord[]) => { void this.refreshMeetings().catch(this.error); };
  async clearNotes() {
    try { for (const note of [...this.state.notes]) await api.deleteNote(note.id); }
    finally { await this.refreshNotes(); }
  }
  async decide(prompt: CalendarPrompt, decision: api.CalendarDecision) {
    await api.calendarDecision(prompt.event.id, decision);
    if (prompt.kind === "start" && this.state.startPrompt?.event.id === prompt.event.id) this.patch({ startPrompt: null });
    if (prompt.kind === "end" && this.state.endPrompt?.event.id === prompt.event.id) this.patch({ endPrompt: null });
  }
  async startDictation() {
    if (!this.ready) { this.error("Recording is unavailable until profile and recovery storage load successfully."); return; }
    if (this.activeMeeting || this.meetingTransition) { this.error("Finish the current meeting before starting dictation."); return; }
    await this.dictation.start();
  }
  async intent(intent: WorkspaceIntent) {
    try {
      if (intent.action === "dismissNotice") this.clearNotice();
      else if (intent.action === "dictate") {
        if (this.dictation.phase === "recording" || this.dictation.phase === "starting") await this.dictation.finish();
        else if (this.dictation.phase === "idle") await this.startDictation();
      } else if (intent.action === "cancelDictation") await this.dictation.finish(true);
      else if (intent.action === "pasteLast") {
        const text = pasteLastText(this.state.notes);
        if (!text) throw new Error("There is no saved text to paste yet.");
        await native.paste(text);
        this.confirm("Pasted");
      } else if (intent.action === "meeting") {
        if (this.meetingTransition) return;
        if (this.dictation.phase !== "idle") throw new Error("Finish dictation before starting a meeting.");
        if (!this.ready) throw new Error("Recording is unavailable until your profile loads.");
        this.meetingTransition = true; void this.publish();
        try {
          if (this.activeMeeting) await api.finishMeeting();
          else {
            const settings = this.state.settings;
            const record = await api.startMeeting({ title: `Meeting ${new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}`,
              microphone: settings.meetingMicrophone, systemAudio: settings.meetingSystemAudio,
              summarizeOnStop: settings.meetingSummarize, liveTranscription: settings.meetingLiveTranscription });
            this.cueMeeting(record);
            this.patch({ meetings: [record, ...this.state.meetings.filter(m => m.id !== record.id)], navigation: { section: "meetings", meetingId: record.id } });
          }
          await this.refreshMeetings();
        } finally { this.meetingTransition = false; void this.publish(); }
      } else if (intent.action === "pauseMeeting") {
        if (this.activeMeeting?.status === "paused") await api.resumeMeeting();
        else if (this.activeMeeting) await api.pauseMeeting();
      } else if (intent.action === "screenshot") {
        const capture = await api.takeScreenshot(intent.kind);
        // The backend already saved it. Never call add_capture a second time.
        if (capture) { await this.refreshNotes(); await emit("workspace://screenshot", capture); this.confirm("Screenshot saved"); }
      } else if (intent.action === "placement") await this.updateSettings({ ...this.state.settings, flowbarPlacement: intent.placement });
      else if (intent.action === "updatePreference") {
        if (intent.key === "showOverlayWhenIdle" && typeof intent.value === "boolean") await this.updateSettings({ ...this.state.settings, showOverlayWhenIdle: intent.value });
        else if (intent.key === "overlayPosition" && typeof intent.value === "string" && ["bottom-center", "bottom-left", "bottom-right", "top-center", "top-right"].includes(intent.value)) await this.updateSettings({ ...this.state.settings, overlayPosition: intent.value, flowbarPlacement: null });
      } else if (intent.action === "inspectNotice" || intent.action === "settings") {
        if (intent.action === "inspectNotice") this.patch({ noticeDetails: true });
        else this.patch({ navigation: { section: "settings", settingsSection: intent.section } });
        const main = await Window.getByLabel("main"); await main?.show(); await main?.setFocus();
      } else if (intent.action === "open") {
        this.patch({ navigation: { section: intent.section ?? "notes", meetingId: intent.meetingId } });
        const main = await Window.getByLabel("main"); await main?.show(); await main?.setFocus();
      }
    } catch (error) { this.error(error); }
  }
}

export const mainController = new MainController();
