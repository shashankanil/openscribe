import { useEffect, useState } from "react";
import { emitTo, listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import type { ParitySettings } from "./api/parityTypes";
import type { WorkspaceStatus } from "./workspaceEvents";
import "./theme.css";

export type ThemePreference = ParitySettings["theme"];
export type ResolvedTheme = "light" | "dark";

export const resolveTheme = (preference: ThemePreference | undefined, systemDark: boolean): ResolvedTheme =>
  preference === "light" || preference === "dark" ? preference : systemDark ? "dark" : "light";

const darkQuery = () => matchMedia("(prefers-color-scheme: dark)");

/** Applies the theme to this window's document and follows the system while set to "system". */
export function useAppliedTheme(preference: ThemePreference | undefined): ResolvedTheme {
  const [systemDark, setSystemDark] = useState(() => darkQuery().matches);
  useEffect(() => {
    const query = darkQuery(), update = () => setSystemDark(query.matches);
    update(); query.addEventListener("change", update);
    return () => query.removeEventListener("change", update);
  }, []);
  const resolved = resolveTheme(preference, systemDark);
  useEffect(() => { document.documentElement.dataset.theme = resolved; }, [resolved]);
  // Native chrome (title bar, window frame) follows the same choice, like NSApp.appearance on macOS.
  // Wait for settings before overriding so "system" never flashes a forced theme.
  useEffect(() => {
    if (preference === undefined) return;
    void getCurrentWindow().setTheme(preference === "system" ? null : preference).catch(console.error);
  }, [preference]);
  return resolved;
}

/** For secondary windows: takes the theme from the main window's workspace status broadcasts. */
export function useWorkspaceTheme(): ResolvedTheme {
  const [preference, setPreference] = useState<ThemePreference>();
  useEffect(() => {
    let disposed = false, unlisten: (() => void) | undefined;
    void listen<WorkspaceStatus>("workspace://status", event => setPreference(event.payload.settings.theme))
      .then(stop => {
        if (disposed) { stop(); return; }
        unlisten = stop;
        return emitTo("main", "workspace://request-state");
      })
      .catch(console.error);
    return () => { disposed = true; unlisten?.(); };
  }, []);
  return useAppliedTheme(preference);
}
