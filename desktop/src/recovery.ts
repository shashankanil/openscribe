import { load, type Store } from "@tauri-apps/plugin-store";
import type { DictationJob } from "./dictation";

/** Recovery state has its own store; the v0.4 profile is only ever read. */
export class DictationRecovery {
  private store?: Store;
  async load(): Promise<DictationJob[]> {
    this.store = await load("dictation-recovery.json", { autoSave: false });
    const jobs = await this.store.get<DictationJob[]>("jobs") ?? [];
    if (!Array.isArray(jobs) || jobs.some(job => !job.id || !job.path)) throw new Error("Dictation recovery history is unreadable. It has been preserved.");
    if (!await this.store.get<boolean>("legacyImported")) {
      const legacy = await load("openscribe.json", { autoSave: false });
      const old = await legacy.get<{ recoveries?: Array<DictationJob & { kind?: string }> }>("state");
      for (const job of old?.recoveries ?? []) {
        if (job.kind === "meeting") continue; // Keep legacy meeting jobs in the untouched legacy store.
        if (!job.id || !job.path) throw new Error("Legacy dictation recovery history is unreadable. It has been preserved.");
        if (!jobs.some(existing => existing.id.toUpperCase() === job.id.toUpperCase())) jobs.push({ ...job, id: job.id.toUpperCase() });
      }
      await this.store.set("jobs", jobs);
      await this.store.set("legacyImported", true);
      await this.store.save();
    }
    return jobs;
  }
  async persist(jobs: DictationJob[]) {
    if (!this.store) throw new Error("Recovery storage is unavailable; recording is blocked.");
    await this.store.set("jobs", jobs);
    await this.store.save();
  }
}
