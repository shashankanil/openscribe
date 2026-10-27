import React, { useEffect, useState, useSyncExternalStore } from "react";
import { AlertTriangle, MoreHorizontal } from "lucide-react";
import type { ParitySettings, ShortcutAction, ShortcutBinding } from "../../api/parityTypes";
import { assignShortcut, bindingFromKey, defaultBindings, holdsKey, rightCtrlBinding, shortcutTitles } from "../../core/shortcuts";
import { mainController } from "../../mainController";
import { reportUiError } from "../../workspaceEvents";

interface ShortcutsSettingsProps {
  settings: ParitySettings;
  onUpdateSettings: (settings: ParitySettings) => void | Promise<void>;
}

// Copy and grouping follow the macOS Shortcuts tab.
const DETAILS: Record<ShortcutAction, string> = {
  dictate: "Tap to start and stop. Hold to talk, release to finish.",
  holdToTalk: "Records only while held down.",
  meeting: "Records your microphone and system audio.",
  screenshotArea: "Drag to select. Saved to today’s note.",
  screenshotWindow: "Click a window. Saved to today’s note.",
  screenshotScreen: "The screen under your pointer. Saved to today’s note.",
  pasteLast: "Pastes your latest dictation into the focused app."
};
const GROUPS: { title: string; footer: string; actions: ShortcutAction[] }[] = [
  { title: "Dictation", footer: "A quick tap of the Dictate shortcut keeps recording until you tap again. Hold it to talk, and release to finish.", actions: ["dictate", "holdToTalk", "pasteLast"] },
  { title: "Meetings & screenshots", footer: "Screenshots are added to today’s note, and text in them becomes searchable.", actions: ["meeting", "screenshotArea", "screenshotWindow", "screenshotScreen"] }
];

const secondaryButton: React.CSSProperties = { background: "var(--os-surface)", color: "var(--os-ink)", border: "1px solid var(--os-line)", borderRadius: 6, padding: "4px 10px", fontSize: 12, fontWeight: 500, cursor: "pointer" };

function Keycaps({ display, dimmed }: { display: string; dimmed: boolean }) {
  return <span style={{ display: "inline-flex", gap: 4, opacity: dimmed ? 0.45 : 1 }}>
    {(display === rightCtrlBinding.display ? [display] : display.split(" ")).map((key, index) => <kbd key={index} style={{ background: "var(--os-surface-muted)", border: "1px solid var(--os-line)", borderRadius: 5, padding: "2px 7px", fontFamily: "inherit", fontSize: 12, fontWeight: 600, color: "var(--os-ink)" }}>{key}</kbd>)}
  </span>;
}

export const ShortcutsSettings: React.FC<ShortcutsSettingsProps> = ({ settings, onUpdateSettings }) => {
  const [recordingAction, setRecordingAction] = useState<ShortcutAction | null>(null);
  const [menuAction, setMenuAction] = useState<ShortcutAction | null>(null);
  const [flash, setFlash] = useState("");
  const [recordError, setRecordError] = useState("");
  const { shortcutFailures } = useSyncExternalStore(mainController.subscribe, mainController.snapshot);
  const shortcuts = settings.shortcuts ?? {};

  useEffect(() => {
    if (!flash) return;
    const timer = window.setTimeout(() => setFlash(""), 2400);
    return () => window.clearTimeout(timer);
  }, [flash]);

  const assign = (action: ShortcutAction, binding: ShortcutBinding | null) => {
    setRecordingAction(null); setMenuAction(null); setRecordError("");
    const { bindings, displaced } = assignShortcut(shortcuts, action, binding);
    void Promise.resolve(onUpdateSettings({ ...settings, shortcuts: bindings }))
      .then(() => { if (displaced) setFlash(`Removed from “${shortcutTitles[displaced]}”`); })
      .catch(reportUiError);
  };

  useEffect(() => {
    if (!recordingAction) return;
    let active = true;
    const handleKeyDown = (event: KeyboardEvent) => {
      event.preventDefault(); event.stopPropagation();
      if (event.key === "Escape" && !event.ctrlKey && !event.altKey && !event.shiftKey) { setRecordingAction(null); setRecordError(""); return; }
      try {
        const binding = bindingFromKey(event);
        if (binding) assign(recordingAction, binding);
      } catch (error) { setRecordError(error instanceof Error ? error.message : String(error)); }
    };
    // Global shortcuts are paused so pressing the current keys records them instead of firing them.
    void mainController.suspendShortcuts(true).then(() => {
      if (active) window.addEventListener("keydown", handleKeyDown, true);
      else return mainController.suspendShortcuts(false);
    }).catch(error => { reportUiError(error); setRecordingAction(null); });
    return () => {
      active = false; window.removeEventListener("keydown", handleKeyDown, true);
      void mainController.suspendShortcuts(false).catch(reportUiError);
    };
  }, [recordingAction, shortcuts, settings, onUpdateSettings]);

  const restoreDefaults = () => {
    setRecordingAction(null); setMenuAction(null);
    void Promise.resolve(onUpdateSettings({ ...settings, shortcuts: defaultBindings })).then(() => setFlash("Shortcuts restored")).catch(reportUiError);
  };

  const row = (action: ShortcutAction, last: boolean) => {
    const binding = shortcuts[action];
    const recording = recordingAction === action;
    const failed = shortcutFailures.includes(action);
    const fallback = defaultBindings[action];
    return <div key={action} style={{ display: "flex", flexWrap: "wrap", gap: 12, alignItems: "center", justifyContent: "space-between", padding: "12px 16px",
      borderBottom: last ? "none" : "1px solid var(--os-line)", background: recording ? "var(--os-accent-soft)" : "transparent" }}>
      <div style={{ minWidth: 0, flex: "1 1 240px" }}>
        <strong style={{ fontSize: 13.5 }}>{shortcutTitles[action]}</strong>
        <div style={{ fontSize: 12, color: recording && recordError ? "var(--os-recording)" : "var(--os-ink-muted)" }}>
          {recording ? recordError || "Press the new shortcut. Escape cancels." : failed ? "Another app is using these keys. Choose different ones." : DETAILS[action]}
        </div>
      </div>
      <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
        {recording ? <span style={{ fontSize: 12, fontWeight: 500, color: "var(--os-accent)" }}>Listening…</span>
          : binding ? <Keycaps display={binding.display} dimmed={failed} />
          : <span style={{ fontSize: 12, color: "var(--os-ink-faint, var(--os-ink-muted))" }}>Not set</span>}
        <button style={recording ? { ...secondaryButton, background: "var(--os-accent)", color: "var(--os-surface)" } : secondaryButton}
          onClick={() => { setRecordError(""); setMenuAction(null); setRecordingAction(recording ? null : action); }}>
          {recording ? "Cancel" : binding ? "Change" : "Set"}
        </button>
        <div style={{ position: "relative" }} onBlur={event => { if (!event.currentTarget.contains(event.relatedTarget)) setMenuAction(null); }}
          onKeyDown={event => { if (event.key === "Escape") { event.stopPropagation(); setMenuAction(null); } }}>
          <button style={{ ...secondaryButton, padding: "4px 6px", display: "flex" }} title="More options" aria-label={`More options for ${shortcutTitles[action]}`}
            aria-haspopup="menu" aria-expanded={menuAction === action} onClick={() => setMenuAction(menuAction === action ? null : action)}>
            <MoreHorizontal size={14} />
          </button>
          {menuAction === action && <div role="menu" style={{ position: "absolute", right: 0, top: "calc(100% + 4px)", zIndex: 20, minWidth: 200, background: "var(--os-surface)",
            border: "1px solid var(--os-line)", borderRadius: 8, boxShadow: "0 8px 24px rgba(0,0,0,0.18)", padding: 4, display: "flex", flexDirection: "column" }}>
            {holdsKey(action) && <button role="menuitem" style={{ textAlign: "left", background: "transparent", border: "none", padding: "6px 10px", fontSize: 12.5, cursor: "pointer", color: "var(--os-ink)", borderRadius: 5 }}
              title="Hold Right Ctrl on its own. It still works as Ctrl with other keys." onClick={() => assign(action, rightCtrlBinding)}>Use Right Ctrl</button>}
            {fallback && <button role="menuitem" className="shortcut-menu-item" style={{ textAlign: "left", background: "transparent", border: "none", padding: "6px 10px", fontSize: 12.5, cursor: "pointer", color: "var(--os-ink)", borderRadius: 5 }}
              onClick={() => assign(action, fallback)}>Use default ({fallback.display})</button>}
            <button role="menuitem" disabled={!binding} style={{ textAlign: "left", background: "transparent", border: "none", padding: "6px 10px", fontSize: 12.5, cursor: binding ? "pointer" : "default", color: binding ? "var(--os-recording)" : "var(--os-ink-muted)", borderRadius: 5 }}
              onClick={() => assign(action, null)}>Remove shortcut</button>
          </div>}
        </div>
      </div>
    </div>;
  };

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 20 }}>
      <div>
        <h3 style={{ fontSize: 16, fontWeight: 600, margin: "0 0 4px" }}>Keyboard Shortcuts</h3>
        <p style={{ fontSize: 13, color: "var(--os-ink-muted)", margin: 0 }}>Shortcuts work in every app and don’t type into it.</p>
      </div>

      {shortcutFailures.length > 0 && (
        <div role="alert" style={{ background: "var(--os-warning-soft)", border: "1px solid var(--os-line)", borderRadius: 8, padding: "10px 14px", display: "flex", alignItems: "flex-start", gap: 10 }}>
          <AlertTriangle size={18} color="var(--os-warning)" style={{ flexShrink: 0, marginTop: 1 }} />
          <div style={{ fontSize: 12.5, color: "var(--os-ink)" }}>
            <strong style={{ display: "block" }}>Some shortcuts aren’t active</strong>
            {shortcutFailures.map(action => shortcutTitles[action]).join(", ")}. Another app may be using their keys; choose different ones.
          </div>
        </div>
      )}

      {GROUPS.map(group => <section key={group.title} style={{ display: "flex", flexDirection: "column", gap: 6 }}>
        <h4 style={{ margin: 0, fontSize: 12, fontWeight: 600, color: "var(--os-ink-muted)", textTransform: "uppercase", letterSpacing: 0.4 }}>{group.title}</h4>
        <div style={{ background: "var(--os-surface)", border: "1px solid var(--os-line)", borderRadius: 10 }}>
          {group.actions.map((action, index) => row(action, index === group.actions.length - 1))}
        </div>
        <p style={{ margin: 0, fontSize: 12, color: "var(--os-ink-muted)" }}>{group.footer}</p>
      </section>)}

      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 12 }}>
        <span role="status" aria-live="polite" style={{ fontSize: 12, color: "var(--os-ink-muted)" }}>{flash}</span>
        <button style={secondaryButton} onClick={restoreDefaults}>Restore defaults</button>
      </div>
    </div>
  );
};
