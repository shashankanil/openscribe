import React, { useEffect, useState } from "react";
import type { CalendarEvent, ParitySettings } from "../../api/parityTypes";
import type { AudioInput } from "../../types";
import { native } from "../../native";
import { providers } from "../../defaults";
import { ProvidersSettings } from "./ProvidersSettings";
import { CalendarSettings } from "./CalendarSettings";
import { PersonalizationSettings } from "./PersonalizationSettings";
import { ShortcutsSettings } from "./ShortcutsSettings";
import { PermissionsView } from "./PermissionsView";
import { SettingsDialog, settingsBox as box, settingsField as field } from "./SettingsDialog";
import { settingsNative, type SaveSettings } from "./settingsSupport";
export type SettingsSection = "general" | "providers" | "shortcuts" | "personalize" | "calendar" | "privacy" | "permissions";
export interface SettingsViewProps {
  settings: ParitySettings;
  calendarEvents?: CalendarEvent[];
  onUpdateSettings: SaveSettings;
  onRefreshCalendar?: () => void | Promise<void>;
  onClearNotesHistory?: () => void | Promise<void>;
  onRevealFlowbar?: () => void | Promise<void>;
  inputs?: AudioInput[];
  onRefreshInputs?: () => AudioInput[] | void | Promise<AudioInput[] | void>;
  initialSection?: SettingsSection;
  selectedSection?: SettingsSection;
  onSectionChange?: (section: SettingsSection) => void;
  hideNavigation?: boolean;
  notesCount?: number;
  meetingsCount?: number;
}
const sections: { id: SettingsSection; label: string }[] = [ { id: "general", label: "General" }, { id: "providers", label: "Providers" }, { id: "shortcuts", label: "Shortcuts" }, { id: "personalize", label: "Personalization" }, { id: "calendar", label: "Calendar" }, { id: "privacy", label: "Privacy" }, { id: "permissions", label: "Permissions" } ];
export function SettingsView({ settings, calendarEvents = [], onUpdateSettings, onRefreshCalendar, onClearNotesHistory, onRevealFlowbar, inputs = [], onRefreshInputs, initialSection = "general", selectedSection, onSectionChange, hideNavigation = false, notesCount, meetingsCount }: SettingsViewProps) {
  const [localSection, setLocalSection] = useState<SettingsSection>(initialSection);
  const section = selectedSection ?? localSection;
  const navigate = (next: SettingsSection) => { setLocalSection(next); onSectionChange?.(next); };
  const [confirmClear, setConfirmClear] = useState(false);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [devices, setDevices] = useState(inputs);
  const [refreshing, setRefreshing] = useState(false);
  const [login, setLogin] = useState<boolean | null>(null);
  const [loginBusy, setLoginBusy] = useState(false);
  const [loginError, setLoginError] = useState("");
  useEffect(() => setDevices(inputs), [inputs]);
  useEffect(() => { let active = true; void settingsNative.getLaunchAtLogin().then(value => { if (active) setLogin(value); }).catch(failure => { if (active) setLoginError(String(failure)); }); return () => { active = false; }; }, []);
  const run = async (action: () => void | Promise<void>) => { setError(""); try { await action(); } catch (failure) { setError(String(failure)); } };
  const update = <K extends keyof ParitySettings>(key: K, value: ParitySettings[K]) => { void run(() => onUpdateSettings({ ...settings, [key]: value })); };
  const refreshInputs = async () => { setRefreshing(true); try { const result = onRefreshInputs ? await onRefreshInputs() : await native.listInputs(); if (result) setDevices(result); setError(""); } catch (failure) { setError(String(failure)); } finally { setRefreshing(false); } };
  const toggle = (key: "showOverlayWhenIdle" | "pasteIntoFocusedApp" | "interactionSounds" | "saveRawAudio", title: string, detail?: string) => <label style={{ display: "flex", justifyContent: "space-between", gap: 16 }}><span>{title}{detail && <small style={{ display: "block", color: "var(--os-ink-muted)" }}>{detail}</small>}</span><input type="checkbox" checked={settings[key]} onChange={event => update(key, event.target.checked)} /></label>;
  return <div className="settings-workspace" style={{ display: "flex", width: "100%", height: "100%", overflow: "hidden" }}>
    {!hideNavigation && <nav className="settings-navigation" aria-label="Settings" style={{ width: 200, flexShrink: 0, borderRight: "1px solid var(--os-line)", padding: 16, display: "flex", flexDirection: "column", gap: 8 }}><h2>Settings</h2>{sections.map(item => <button key={item.id} aria-current={section === item.id ? "page" : undefined} onClick={() => navigate(item.id)}>{item.label}</button>)}</nav>}
    <div className="settings-content" style={{ flex: 1, minWidth: 0, overflowY: "auto", padding: "28px 32px" }}>
      <h2>{sections.find(item => item.id === section)?.label}</h2>
      {error && <p role="alert">{error}</p>}
      {section === "general" && <div style={{ display: "flex", flexDirection: "column", gap: 22 }}>
        <section style={box}><h3>Appearance</h3><div role="group" aria-label="Appearance" style={{ display: "flex", gap: 14 }}>{(["system", "light", "dark"] as const).map(theme => <button key={theme} aria-pressed={settings.theme === theme} onClick={() => update("theme", theme)} style={{ flex: 1, border: `2px solid ${settings.theme === theme ? "var(--os-accent)" : "var(--os-line)"}`, borderRadius: 10, padding: 8, background: "var(--os-surface)", color: "var(--os-ink)" }}>
          <span aria-hidden="true" style={{ display: "flex", height: 72, marginBottom: 8, borderRadius: 6, overflow: "hidden", background: theme === "dark" ? "#20242b" : theme === "system" ? "linear-gradient(110deg,#faf7f2 50%,#20242b 50%)" : "#faf7f2" }}><span style={{ width: "25%", background: "#8e8c8a44" }} /><span style={{ flex: 1, padding: 10 }}><span style={{ display: "block", height: 7, width: "75%", marginBottom: 7, borderRadius: 3, background: "#ad9978" }} /><span style={{ display: "block", height: 5, width: "90%", background: "#97979788" }} /><span style={{ display: "block", height: 5, width: "60%", marginTop: 7, background: "#97979788" }} /></span></span>{theme[0].toUpperCase() + theme.slice(1)}
        </button>)}</div></section>
        <section style={box}><h3>Startup</h3><label style={{ display: "flex", justifyContent: "space-between" }}>Launch at login<input type="checkbox" aria-label="Launch at login" disabled={login === null || loginBusy} checked={login ?? false} onChange={event => { const enabled = event.target.checked; setLoginBusy(true); setLoginError(""); void settingsNative.setLaunchAtLogin(enabled).then(() => setLogin(enabled)).catch(failure => setLoginError(String(failure))).finally(() => setLoginBusy(false)); }} /></label><small>{login === null ? "Startup state unavailable until Windows responds." : "OpenScribe is ready when you log in to Windows."}</small>{loginError && <><p role="alert">{loginError}</p><button disabled={loginBusy} onClick={() => { setLoginBusy(true); void settingsNative.getLaunchAtLogin().then(value => { setLogin(value); setLoginError(""); }).catch(failure => setLoginError(String(failure))).finally(() => setLoginBusy(false)); }}>Refresh startup state</button></>}</section>
        <section style={box}><h3>Recording</h3><label style={field}>Microphone<select value={settings.microphoneDeviceUID} onChange={event => update("microphoneDeviceUID", event.target.value)}><option value="">System default</option>{devices.map(input => <option key={input.id} value={input.id}>{input.name}</option>)}{settings.microphoneDeviceUID && !devices.some(input => input.id === settings.microphoneDeviceUID) && <option value={settings.microphoneDeviceUID}>Selected microphone unavailable</option>}</select></label><button disabled={refreshing} onClick={() => { void refreshInputs(); }}>{refreshing ? "Refreshing..." : "Refresh microphones"}</button><div>Dictation, meetings, and screenshots from any app. <button onClick={() => navigate("shortcuts")}>Edit shortcuts</button></div>{toggle("pasteIntoFocusedApp", "Paste into the focused app", "Recordings started in the workspace are saved to Notes.")}</section>
        <section style={box}><h3>Flowbar</h3>{toggle("showOverlayWhenIdle", "Keep on screen when idle", "Hover for dictation, meetings, and screenshots.")}
          <label style={field}>Position<select value={settings.flowbarPlacement ? "custom" : settings.overlayPosition ?? "bottom-center"} onChange={event => { if (event.target.value !== "custom") void run(() => onUpdateSettings({ ...settings, overlayPosition: event.target.value, flowbarPlacement: null })); }}>{["bottom-center", "bottom-left", "bottom-right", "top-center", "top-right"].map(position => <option key={position} value={position}>{position.replace("-", " ")}</option>)}{settings.flowbarPlacement && <option value="custom">Where I placed it</option>}</select></label>
          <small>Drag the Flowbar anywhere. It snaps to the center and edges and remembers where you leave it.</small>{onRevealFlowbar && <button onClick={() => { void run(onRevealFlowbar); }}>Show me the Flowbar</button>}{toggle("interactionSounds", "Recording sounds")}
        </section>
      </div>}
      {section === "providers" && <ProvidersSettings settings={settings} inputs={devices} onUpdateSettings={onUpdateSettings} />}
      {section === "shortcuts" && <ShortcutsSettings settings={settings} onUpdateSettings={onUpdateSettings} />}
      {section === "personalize" && <PersonalizationSettings settings={settings} onUpdateSettings={onUpdateSettings} />}
      {section === "calendar" && <CalendarSettings settings={settings} events={calendarEvents} onUpdateSettings={onUpdateSettings} onRefreshCalendar={onRefreshCalendar} />}
      {section === "permissions" && <PermissionsView onOpenCalendar={() => navigate("calendar")} />}
      {section === "privacy" && <div style={{ display: "flex", flexDirection: "column", gap: 20 }}>
        <section style={box}><h3>On this device</h3><span>Notes: {notesCount ?? "Count unavailable"}</span><span>Meetings: {meetingsCount ?? "Count unavailable"}</span>{toggle("saveRawAudio", "Keep dictation audio", "Keep audio after successful transcription.")}<small>Notes, screenshots and meeting history stay locally. OpenScribe does not sync your library to a cloud account.</small></section>
        <section style={box}><h3>Your providers</h3><p>Recordings are sent to {providers.find(item => item.id === settings.speechProvider)?.title ?? settings.speechProvider} for transcription.</p><p>{settings.cleanupEnabled ? `Writing is sent to ${providers.find(item => item.id === settings.languageModelProvider)?.title ?? settings.languageModelProvider} for cleanup. Meeting summaries also use your writing provider.` : "Dictation cleanup is off. Meeting summaries and enabled spoken corrections can still use your writing provider."}</p><button onClick={() => navigate("providers")}>Manage providers</button></section>
        {onClearNotesHistory && <section style={box}><h3>Note history</h3><p>Permanently delete local notes. Meetings and provider keys are kept.</p><button onClick={() => { setError(""); setConfirmClear(true); }}>Clear note history...</button></section>}
      </div>}
    </div>
    {confirmClear && <SettingsDialog title="Delete all notes?" busy={busy} onClose={() => setConfirmClear(false)}><p>This permanently removes {notesCount === undefined ? "all" : notesCount} local notes. Meetings and provider keys are kept.</p><button disabled={busy} onClick={() => setConfirmClear(false)}>Cancel</button> <button disabled={busy} onClick={() => { setBusy(true); void Promise.resolve().then(() => onClearNotesHistory?.()).then(() => { setConfirmClear(false); setError(""); }).catch(failure => setError(String(failure))).finally(() => setBusy(false)); }}>{busy ? "Deleting..." : "Delete all notes"}</button>{error && <p role="alert">{error}</p>}</SettingsDialog>}
  </div>;
}
