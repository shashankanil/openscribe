import type { NoteCapture, ParitySettings } from "./api/parityTypes";

export type DictationPhase = "idle" | "starting" | "recording" | "transcribing" | "cleaning";
export interface DictationJob { id: string; path: string; duration: number; createdAt: string; rawText?: string; text?: string; sourceApplication?: string; sourceBundleIdentifier?: string }
export interface DictationDependencies {
  settings(): ParitySettings;
  start(device?: string): Promise<unknown>;
  stop(cancel?: boolean): Promise<{ path: string; duration: number; transcript?: string | null }>;
  transcribe(path: string, settings: ParitySettings): Promise<string>;
  transform(text: string, settings: ParitySettings): Promise<string>;
  save(capture: NoteCapture): Promise<unknown>;
  persist(jobs: DictationJob[]): Promise<void>;
  removeAudio(path: string): Promise<unknown>;
  paste(text: string): Promise<unknown>;
  changed(phase: DictationPhase, jobs: DictationJob[]): void;
  error(error: unknown): void;
  sourceApp?(): Promise<{ name: string; id: string } | null>;
  cancelProcessing?(): Promise<void>;
  success?(message: string): void;
  /** Played as on macOS: when the microphone is live, and when a kept recording stops. */
  cue?(cue: "start" | "stop"): void;
}

/** The main window owns capture; other windows send intents to this controller. */
export class DictationController {
  phase: DictationPhase = "idle";
  jobs: DictationJob[] = [];
  private pendingStop = false;
  private pendingCancel = false;
  private processingCancelled = false;
  private source: { name: string; id: string } | null = null;
  private activeJob?: DictationJob;
  constructor(private deps: DictationDependencies) {}
  private changed() { this.deps.changed(this.phase, [...this.jobs]); }
  private async persist() { await this.deps.persist(this.jobs); this.changed(); }
  async start() {
    if (this.phase !== "idle") return;
    this.phase = "starting"; this.pendingStop = false; this.pendingCancel = false; this.processingCancelled = false; this.changed();
    try {
      this.source = this.deps.sourceApp ? await this.deps.sourceApp().catch(() => null) : null;
      await this.deps.start(this.deps.settings().microphoneDeviceUID || undefined);
      this.phase = "recording"; this.changed();
      this.deps.cue?.("start");
      if (this.pendingStop) await this.finish(this.pendingCancel);
    } catch (error) { this.phase = "idle"; this.changed(); this.deps.error(error); }
  }
  async finish(cancel = false) {
    if (cancel && (this.phase === "transcribing" || this.phase === "cleaning")) {
      this.processingCancelled = true;
      await this.deps.cancelProcessing?.().catch(this.deps.error);
      return;
    }
    if (this.phase === "starting") { this.pendingStop = true; this.pendingCancel ||= cancel; return; }
    if (this.phase !== "recording") return;
    this.phase = "transcribing"; this.changed();
    try {
      const recording = await this.deps.stop(cancel);
      if (cancel || this.processingCancelled) { await this.deps.removeAudio(recording.path); this.deps.success?.("Cancelled"); return; }
      this.deps.cue?.("stop");
      const job: DictationJob = { path: recording.path, duration: recording.duration, id: crypto.randomUUID().toUpperCase(), createdAt: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"), ...(this.source ? { sourceApplication: this.source.name, sourceBundleIdentifier: this.source.id } : {}) };
      this.jobs.push(job);
      if (recording.transcript?.trim()) job.rawText = recording.transcript;
      this.activeJob = job;
      await this.persist(); // Keep the recording recoverable before any provider request.
      await this.process(job);
    } catch (error) { if (this.processingCancelled) await this.removeCancelledJob(); else this.deps.error(error); }
    finally { this.activeJob = undefined; this.phase = "idle"; this.changed(); }
  }
  async retry() {
    if (this.phase !== "idle" || !this.jobs.length) return;
    this.processingCancelled = false; this.phase = "transcribing"; this.changed();
    try { this.activeJob = this.jobs[0]; await this.process(this.activeJob); }
    catch (error) { if (this.processingCancelled) await this.removeCancelledJob(); else this.deps.error(error); }
    finally { this.activeJob = undefined; this.phase = "idle"; this.changed(); }
  }
  private async process(job: DictationJob) {
    if (this.processingCancelled) throw new Error("Cancelled");
    const current = this.deps.settings();
    const tone = job.sourceBundleIdentifier ? current.appWritingTones?.[job.sourceBundleIdentifier.toLowerCase()] : undefined;
    const settings = tone && ["natural", "casual", "formal"].includes(tone) ? { ...current, writingTone: tone as ParitySettings["writingTone"] } : current;
    if (job.rawText == null) { job.rawText = await this.deps.transcribe(job.path, settings); await this.persist(); }
    if (this.processingCancelled) throw new Error("Cancelled");
    if (job.text == null) {
      this.phase = "cleaning"; this.changed();
      job.text = await this.deps.transform(job.rawText, settings);
      if (this.processingCancelled) throw new Error("Cancelled");
      await this.persist();
    }
    const text = job.text;
    if (this.processingCancelled) throw new Error("Cancelled");
    await this.deps.save({ id: job.id, createdAt: job.createdAt, title: text.slice(0, 80), rawText: job.rawText, text, duration: job.duration, kind: "dictation", sourceApplication: job.sourceApplication, sourceBundleIdentifier: job.sourceBundleIdentifier });
    const old = this.jobs; this.jobs = this.jobs.filter(j => j.id !== job.id);
    try { await this.persist(); } catch (error) { this.jobs = old; throw error; }
    if (!settings.saveRawAudio) await this.deps.removeAudio(job.path).catch(this.deps.error);
    if (this.processingCancelled) throw new Error("Cancelled");
    if (settings.pasteIntoFocusedApp) await this.deps.paste(text).catch(this.deps.error);
    this.deps.success?.("Saved");
  }
  private async removeCancelledJob() {
    const job = this.activeJob;
    if (job) {
      const old = this.jobs; this.jobs = this.jobs.filter(item => item.id !== job.id);
      try { await this.persist(); } catch (error) { this.jobs = old; this.deps.error(error); return; }
      await this.deps.removeAudio(job.path).catch(this.deps.error);
    }
    this.deps.success?.("Cancelled");
  }
  async discard() {
    if (this.phase !== "idle") return;
    const old = this.jobs; this.jobs = [];
    try { await this.persist(); } catch (error) { this.jobs = old; this.deps.error(error); return; }
    for (const job of old) await this.deps.removeAudio(job.path).catch(this.deps.error);
  }
}
