import { load, type Store } from "@tauri-apps/plugin-store";
import { initialState } from "./defaults";
import type { PersistedState } from "./types";

let store: Store | undefined;

function mergeState(value?: Partial<PersistedState> | null): PersistedState {
  return {
    ...initialState,
    ...value,
    settings: { ...initialState.settings, ...(value?.settings ?? {}) },
    notes: value?.notes ?? [],
    meetings: value?.meetings ?? [],
    calendar: value?.calendar ?? [],
    recoveries: value?.recoveries ?? []
  };
}

export async function loadState(): Promise<PersistedState> {
  try {
    store = await load("openscribe.json", { autoSave: 150 });
    return mergeState(await store.get<Partial<PersistedState>>("state"));
  } catch {
    const raw = localStorage.getItem("openscribe-state");
    return mergeState(raw ? JSON.parse(raw) : null);
  }
}

export async function saveState(state: PersistedState) {
  if (store) {
    await store.set("state", state);
    await store.save();
  } else {
    localStorage.setItem("openscribe-state", JSON.stringify(state));
  }
}
