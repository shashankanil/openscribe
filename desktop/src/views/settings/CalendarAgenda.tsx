import { useState } from "react";
import { ChevronLeft, ChevronRight } from "lucide-react";
import { openUrl } from "@tauri-apps/plugin-opener";
import type { CalendarEvent, ParitySettings } from "../../api/parityTypes";
import { localDay } from "../../core/dailyNotes";
import { matchesExclusion } from "../../core/calendarPolicy";
import { reportUiError } from "../../workspaceEvents";
import { eventsOnDay, monthDays } from "./calendarAgendaHelpers";

export function CalendarAgenda({ events, settings }: { events: CalendarEvent[]; settings: ParitySettings }) {
  const [selectedDay, setSelectedDay] = useState(() => new Date());
  const [month, setMonth] = useState(() => new Date());
  const [source, setSource] = useState("all");
  const visible = events.filter(event => source === "all" || event.calendarID === source);
  const agenda = eventsOnDay(visible, selectedDay);
  const moveMonth = (offset: number) => {
    const next = new Date(month.getFullYear(), month.getMonth() + offset, 1);
    setMonth(next); setSelectedDay(next);
  };
  const sources = [...new Map(events.map(event => [event.calendarID, event.calendarName])).entries()];
  const time = (value: string) => new Date(value).toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });

  return <>
    <div className="ui-toolbar" style={{ display: "flex", justifyContent: "space-between" }}>
      <span style={{ color: "var(--os-ink-muted)", fontSize: 12 }}>{settings.calendarEnabled ? "Meeting prompts on" : "Browsing only"}</span>
      <select aria-label="Show calendar" value={source} onChange={event => setSource(event.target.value)}>
        <option value="all">All calendars</option>
        {sources.map(([id, name]) => <option key={id} value={id}>{name}</option>)}
      </select>
    </div>
    <section className="calendar-month" aria-label="Calendar month">
      <div className="ui-toolbar" style={{ display: "flex", justifyContent: "space-between", marginBottom: 16 }}>
        <strong>{month.toLocaleDateString(undefined, { month: "long", year: "numeric" })}</strong>
        <div style={{ display: "flex", gap: 8 }}>
          <button className="quiet" onClick={() => { const today = new Date(); setMonth(today); setSelectedDay(today); }}>Today</button>
          <button className="quiet" aria-label="Previous month" onClick={() => moveMonth(-1)}><ChevronLeft size={14} /></button>
          <button className="quiet" aria-label="Next month" onClick={() => moveMonth(1)}><ChevronRight size={14} /></button>
        </div>
      </div>
      <div className="calendar-days">
        {Array.from({ length: 7 }, (_, index) => <span className="calendar-weekday" key={index}>{new Date(2026, 0, 4 + index).toLocaleDateString(undefined, { weekday: "short" })}</span>)}
        {monthDays(month).map((day, index) => {
          if (!day) return <div key={index} />;
          const entries = eventsOnDay(visible, day);
          return <button className="calendar-day" key={index} aria-pressed={localDay(day) === localDay(selectedDay)} aria-current={localDay(day) === localDay(new Date()) ? "date" : undefined} aria-label={`${day.toLocaleDateString(undefined, { dateStyle: "full" })}, ${entries.length} events`} onClick={() => setSelectedDay(day)}>
            <strong>{day.getDate()}</strong>
            {entries.slice(0, 2).map(event => <span key={event.occurrenceId ?? event.id} title={event.title}>{event.title}</span>)}
            {entries.length > 2 && <span>+{entries.length - 2} more</span>}
          </button>;
        })}
      </div>
    </section>
    <section className="calendar-agenda" aria-label="Day agenda">
      <h4>{selectedDay.toLocaleDateString(undefined, { weekday: "long", month: "short", day: "numeric" })} · {agenda.length} {agenda.length === 1 ? "event" : "events"}</h4>
      {!agenda.length && <p style={{ color: "var(--os-ink-muted)", fontSize: 13 }}>Nothing scheduled. A little room to breathe.</p>}
      {agenda.map(event => {
        const excluded = event.excluded || matchesExclusion(event, settings.calendarExcludedTitles);
        const eligible = !event.isAllDay && (!settings.calendarMeetingsOnly || event.hasAttendees || !!event.link);
        const watched = settings.calendarSources.some(source => source.id === event.calendarID);
        const status = Date.parse(event.end) < Date.now() ? "Ended" : excluded ? "Excluded by title rule" : !eligible ? "No recording prompt" : settings.calendarEnabled && watched ? "Will ask before recording" : "Browsing only";
        const link = event.link;
        return <article className="calendar-event" key={event.occurrenceId ?? event.id}>
          <time>{event.isAllDay ? "All day" : `${time(event.start)} – ${time(event.end)}`}</time>
          <div><strong>{event.title || "Untitled event"}</strong><small>{event.calendarName}</small><small>{status}</small></div>
          {link && /^https?:\/\//i.test(link) && <button className="quiet" onClick={() => { void openUrl(link).catch(reportUiError); }}>Join</button>}
        </article>;
      })}
    </section>
  </>;
}
