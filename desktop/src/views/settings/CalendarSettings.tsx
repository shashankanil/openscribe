import React, { useState } from "react";
import {
  Calendar as CalendarIcon,
  Check,
  ExternalLink,
  Plus,
  RefreshCw,
  Trash2,
  X
} from "lucide-react";
import { CalendarAgenda } from "./CalendarAgenda";
import type { SaveSettings } from "./settingsSupport";
import type { CalendarEvent, CalendarSource, ParitySettings } from "../../api/parityTypes";

interface CalendarSettingsProps {
  settings: ParitySettings;
  events?: CalendarEvent[];
  onUpdateSettings: SaveSettings;
  onRefreshCalendar?: () => void | Promise<void>;
}

export const CalendarSettings: React.FC<CalendarSettingsProps> = ({
  settings,
  events = [],
  onUpdateSettings,
  onRefreshCalendar
}) => {
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const persist = async (next: ParitySettings, done?: () => void) => { setBusy(true); setError(""); try { await onUpdateSettings(next); done?.(); } catch (failure) { setError(String(failure)); } finally { setBusy(false); } };
  const [sourceName, setSourceName] = useState("");
  const [sourceUrl, setSourceUrl] = useState("");
  const [excludedTitleInput, setExcludedTitleInput] = useState("");

  const handleToggle = (key: keyof ParitySettings, val: boolean) => {
    void persist({ ...settings, [key]: val });
  };

  const handleAddSource = () => {
    if (!sourceName.trim() || !sourceUrl.trim()) return;
    const newSource: CalendarSource = {
      id: crypto.randomUUID().toUpperCase(),
      name: sourceName.trim(),
      url: sourceUrl.trim()
    };
    void persist({
      ...settings,
      calendarSources: [...settings.calendarSources, newSource]
    }, () => { setSourceName(""); setSourceUrl(""); });
  };

  const handleRemoveSource = (id: string) => {
    void persist({
      ...settings,
      calendarSources: settings.calendarSources.filter((s) => s.id !== id)
    });
  };

  const handleAddExcludedTitle = () => {
    const title = excludedTitleInput.trim();
    if (!title || settings.calendarExcludedTitles.includes(title)) return;
    void persist({
      ...settings,
      calendarExcludedTitles: [...settings.calendarExcludedTitles, title]
    }, () => setExcludedTitleInput(""));
  };

  const handleRemoveExcludedTitle = (title: string) => {
    void persist({
      ...settings,
      calendarExcludedTitles: settings.calendarExcludedTitles.filter((t) => t !== title)
    });
  };

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 20 }} aria-busy={busy}>
      {error && <p role="alert">{error}</p>}
      <fieldset disabled={busy} style={{ border: 0, padding: 0, margin: 0, display: "contents" }}>
      {/* Header */}
      <div className="ui-toolbar" style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
        <div>
          <h3 style={{ fontSize: 16, fontWeight: 600, margin: "0 0 4px" }}>
            Calendar Recording & Sources
          </h3>
          <p style={{ fontSize: 13, color: "var(--os-ink-muted)", margin: 0 }}>
            Subscribe to iCal/ICS feeds from Google Calendar, Outlook, or Apple Calendar.
          </p>
        </div>
        {onRefreshCalendar && (
          <button
            disabled={busy}
            onClick={() => { setBusy(true); setError(""); void Promise.resolve().then(() => onRefreshCalendar?.()).catch(failure => setError(String(failure))).finally(() => setBusy(false)); }}
            style={{
              background: "transparent",
              border: "1px solid var(--os-line)",
              borderRadius: 6,
              padding: "5px 10px",
              fontSize: 12,
              cursor: "pointer",
              display: "flex",
              alignItems: "center",
              gap: 5
            }}
          >
            <RefreshCw size={12} /> Refresh
          </button>
        )}
      </div>

      <CalendarAgenda events={events} settings={settings} />

      {/* Recording Preferences Group */}
      <div
        style={{
          background: "var(--os-surface)",
          border: "1px solid var(--os-line)",
          borderRadius: 10,
          padding: "16px 20px",
          display: "flex",
          flexDirection: "column",
          gap: 16
        }}
      >
        <div className="settings-row" style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
          <div>
            <strong style={{ fontSize: 13.5, display: "block" }}>
              Ask to record calendar meetings
            </strong>
            <span style={{ fontSize: 12, color: "var(--os-ink-muted)" }}>
              Prompts before upcoming scheduled meetings start.
            </span>
          </div>
          <input
            type="checkbox"
            disabled={busy}
            checked={settings.calendarEnabled}
            onChange={(e) => handleToggle("calendarEnabled", e.target.checked)}
          />
        </div>

        <div style={{ height: 1, background: "var(--os-line)" }} />

        <div className="settings-row" style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
          <div>
            <strong style={{ fontSize: 13.5, display: "block" }}>
              Only events with meeting links
            </strong>
            <span style={{ fontSize: 12, color: "var(--os-ink-muted)" }}>
              Filters out appointments that do not have Google Meet, Zoom, Teams, or Webex links.
            </span>
          </div>
          <input
            type="checkbox"
            disabled={busy}
            checked={settings.calendarMeetingsOnly}
            onChange={(e) => handleToggle("calendarMeetingsOnly", e.target.checked)}
          />
        </div>

        <div style={{ height: 1, background: "var(--os-line)" }} />

        <div className="settings-row" style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
          <div>
            <strong style={{ fontSize: 13.5, display: "block" }}>
              Auto-start after 60 seconds
            </strong>
            <span style={{ fontSize: 12, color: "var(--os-ink-muted)" }}>
              If unanswered, starts local recording so nothing is lost.
            </span>
          </div>
          <input
            type="checkbox"
            disabled={busy}
            checked={settings.calendarAutoStart}
            onChange={(e) => handleToggle("calendarAutoStart", e.target.checked)}
          />
        </div>

        <div style={{ height: 1, background: "var(--os-line)" }} />

        <div className="settings-row" style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
          <div>
            <strong style={{ fontSize: 13.5, display: "block" }}>
              Summarize when meeting ends
            </strong>
            <span style={{ fontSize: 12, color: "var(--os-ink-muted)" }}>
              Automatically runs transcription and summary when the scheduled end time is reached.
            </span>
          </div>
          <input
            type="checkbox"
            disabled={busy}
            checked={settings.calendarSummarize}
            onChange={(e) => handleToggle("calendarSummarize", e.target.checked)}
          />
        </div>
      </div>

      {/* Excluded Titles */}
      <div
        style={{
          background: "var(--os-surface)",
          border: "1px solid var(--os-line)",
          borderRadius: 10,
          padding: "16px 20px"
        }}
      >
        <h4 style={{ fontSize: 13.5, fontWeight: 600, margin: "0 0 6px" }}>
          Always skip matching titles
        </h4>
        <p style={{ fontSize: 12, color: "var(--os-ink-muted)", margin: "0 0 12px" }}>
          Never prompt to record meetings whose title contains these words (e.g. personal, 1:1).
        </p>
        <div className="form-add-row" style={{ display: "flex", gap: 8, marginBottom: 10 }}>
          <input
            type="text"
            value={excludedTitleInput}
            onChange={(e) => setExcludedTitleInput(e.target.value)}
            placeholder="e.g. 1:1, Lunch, Doctor"
            style={{ flex: 1, minWidth: 0, minHeight: 0, padding: "6px 10px", borderRadius: 6, border: "1px solid var(--os-line)", fontSize: 13 }}
          />
          <button
            disabled={busy || !excludedTitleInput.trim() || settings.calendarExcludedTitles.includes(excludedTitleInput.trim())}
            onClick={handleAddExcludedTitle}
            style={{
              background: "var(--os-accent)",
              color: "var(--os-primary-text)",
              border: "none",
              borderRadius: 6,
              padding: "0 14px",
              fontSize: 12,
              fontWeight: 600,
              cursor: "pointer"
            }}
          >
            Add
          </button>
        </div>
        <div style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
          {settings.calendarExcludedTitles.map((phrase) => (
            <span
              key={phrase}
              style={{
                background: "var(--os-surface-muted)",
                borderRadius: 4,
                padding: "2px 8px",
                fontSize: 12,
                display: "flex",
                alignItems: "center",
                gap: 6
              }}
            >
              {phrase}
              <button
                disabled={busy}
                aria-label={`Remove exclusion ${phrase}`}
                onClick={() => handleRemoveExcludedTitle(phrase)}
                style={{ background: "transparent", border: "none", cursor: "pointer", padding: 0 }}
              >
                <X size={12} color="var(--os-ink-muted)" />
              </button>
            </span>
          ))}
        </div>
      </div>

      {/* Calendar Sources */}
      <div
        style={{
          background: "var(--os-surface)",
          border: "1px solid var(--os-line)",
          borderRadius: 10,
          padding: "16px 20px"
        }}
      >
        <h4 style={{ fontSize: 13.5, fontWeight: 600, margin: "0 0 6px" }}>
          Calendar Sources (ICS / iCal Feeds)
        </h4>
        <p style={{ fontSize: 12, color: "var(--os-ink-muted)", margin: "0 0 12px" }}>
          Add your Google Calendar secret iCal URL or Outlook published calendar URL.
        </p>

        <div className="form-add-row" style={{ display: "flex", gap: 8, marginBottom: 12 }}>
          <input
            type="text"
            placeholder="Calendar Name (e.g. Work)"
            value={sourceName}
            onChange={(e) => setSourceName(e.target.value)}
            style={{ width: 140, padding: "6px 10px", borderRadius: 6, border: "1px solid var(--os-line)", fontSize: 13 }}
          />
          <input
            type="text"
            placeholder="https://calendar.google.com/.../basic.ics"
            value={sourceUrl}
            onChange={(e) => setSourceUrl(e.target.value)}
            style={{ flex: 1, minWidth: 0, minHeight: 0, padding: "6px 10px", borderRadius: 6, border: "1px solid var(--os-line)", fontSize: 13 }}
          />
          <button
            disabled={busy || !sourceName.trim() || !sourceUrl.trim()}
            onClick={handleAddSource}
            style={{
              background: "var(--os-accent)",
              color: "var(--os-primary-text)",
              border: "none",
              borderRadius: 6,
              padding: "0 14px",
              fontSize: 12,
              fontWeight: 600,
              cursor: "pointer"
            }}
          >
            Add source
          </button>
        </div>

        <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
          {settings.calendarSources.map((source) => (
            <div
              key={source.id}
              style={{
                display: "flex",
                flexWrap: "wrap", gap: 12,
                alignItems: "center",
                justifyContent: "space-between",
                padding: "8px 12px",
                background: "var(--os-surface-muted)",
                borderRadius: 6
              }}
            >
              <div>
                <strong style={{ fontSize: 13, display: "block" }}>{source.name}</strong>
                <span style={{ fontSize: 11.5, color: "var(--os-ink-muted)" }}>{source.url}</span>
              </div>
              <button
                disabled={busy}
                aria-label={`Remove ${source.name}`}
                onClick={() => handleRemoveSource(source.id)}
                style={{ background: "transparent", border: "none", color: "color-mix(in srgb, var(--os-recording) 72%, var(--os-ink))", cursor: "pointer" }}
              >
                <Trash2 size={13} />
              </button>
            </div>
          ))}
        </div>
      </div>
      </fieldset>
    </div>
  );
};
