import React, { useCallback, useEffect, useState } from "react";
import { settingsNative, type CaptureReadiness } from "./settingsSupport";
import { settingsBox } from "./SettingsDialog";
export interface PermissionsViewProps { onReadinessChange?: (readiness: CaptureReadiness | null) => void; onOpenCalendar?: () => void }
export function PermissionsView({ onReadinessChange, onOpenCalendar }: PermissionsViewProps) {
  const [readiness, setReadiness] = useState<CaptureReadiness | null>(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const refresh = useCallback(async () => {
    setBusy(true);
    try { const result = await settingsNative.captureReadiness(); setReadiness(result); onReadinessChange?.(result); setError(""); }
    catch (failure) { setReadiness(null); onReadinessChange?.(null); setError(String(failure)); }
    finally { setBusy(false); }
  }, [onReadinessChange]);
  useEffect(() => { void refresh(); const focus = () => { void refresh(); }; window.addEventListener("focus", focus); return () => window.removeEventListener("focus", focus); }, [refresh]);
  const open = async (section: "microphone" | "sound") => { try { await settingsNative.openWindowsSettings(section); } catch (failure) { setError(String(failure)); } };
  return <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
    <p>Windows controls microphone privacy for desktop apps. System audio uses the output device; it does not need the macOS Screen Recording permission. Pasting uses Windows input and can be blocked by elevated apps.</p>
    {([ ["microphone", "Microphone"], ["paste", "Paste into other apps"], ["systemAudio", "System audio"], ["calendar", "Calendar sources"] ] as const).map(([key, title]) => <section key={key} style={settingsBox}>
      <strong>{title}</strong><span role="status">{readiness ? readiness[key].ready ? key === "calendar" ? "Sources configured" : "Ready" : key === "calendar" ? "No sources configured" : "Needs attention" : "Not checked"}</span>
      <small>{readiness?.[key].detail ?? "Refresh to check availability."}</small>
      {key === "microphone" && <button onClick={() => { void open("microphone"); }}>Open microphone privacy settings</button>}
      {key === "systemAudio" && <button onClick={() => { void open("sound"); }}>Open sound settings</button>}
      {key === "calendar" && <><small>Windows uses subscribed ICS URLs or files, rather than macOS Calendar access. Configured sources are not a network check; refresh Calendar to validate access.</small>{onOpenCalendar && <button onClick={onOpenCalendar}>Manage calendar sources</button>}</>}
    </section>)}
    {error && <p role="alert">{error}</p>}<button disabled={busy} onClick={() => { void refresh(); }}>{busy ? "Checking..." : "Refresh readiness"}</button>
  </div>;
}
