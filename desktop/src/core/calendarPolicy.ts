export interface CalendarEvent {
  id: string; title: string; start: string; end: string; calendarID: string; calendarName: string;
  link?: string | null; hasAttendees: boolean; excluded: boolean; isAllDay: boolean;
}
export interface CalendarPolicySettings {
  calendarEnabled: boolean; calendarSources: { id: string }[]; calendarExcludedTitles: string[];
  calendarAutoStart: boolean; calendarMeetingsOnly: boolean; calendarSummarize: boolean; meetingLiveTranscription: boolean;
}
export const calendarDefaults: CalendarPolicySettings = { calendarEnabled: false, calendarSources: [], calendarExcludedTitles: [], calendarAutoStart: true, calendarMeetingsOnly: true, calendarSummarize: true, meetingLiveTranscription: true };
export function meetingLink(text: string): string | undefined {
  const hosts = ["meet.google.com","zoom.us","teams.microsoft.com","teams.live.com","webex.com"];
  for (const match of text.matchAll(/https:\/\/[^\s<>"\u0000-\u001f]+/gi)) {
    try { const url = new URL(match[0].replace(/[),.;!?]+$/, ""));
      if (url.protocol === "https:" && hosts.some(h => url.hostname === h || url.hostname.endsWith(`.${h}`))) return url.href;
    } catch { /* Not a URL. */ }
  }
}
export const matchesExclusion = (event: CalendarEvent, phrases: string[]) => phrases.some(p => p.trim() !== "" && event.title.toLocaleLowerCase().includes(p.trim().toLocaleLowerCase()));
export function isDue(event: CalendarEvent, now: number, selected: string[], handled: ReadonlySet<string>, meetingsOnly: boolean, excludedTitles: string[] = []): boolean {
  const start = Date.parse(event.start), end = Date.parse(event.end);
  return !event.excluded && !event.isAllDay && !matchesExclusion(event,excludedTitles) && selected.includes(event.calendarID) && !handled.has(event.id) && start <= now && now-start <= 120_000 && end > now && (!meetingsOnly || event.link != null || event.hasAttendees);
}
/** Native event payload: dates use the same ISO strings as CalendarEvent. */
export interface CalendarPrompt { event: CalendarEvent; kind: "start" | "end"; deadline: string; automatic: boolean; message: string }
export type CalendarDecision = "skip" | "decline" | "notHappening" | "allow" | "start" | "extend" | "finish";
export const makePrompt = (event: CalendarEvent, kind: "start" | "end", now: number, autoStart: boolean): CalendarPrompt => ({ event, kind, deadline: new Date(now+60_000).toISOString(), automatic: kind === "end" || autoStart, message: kind === "start" ? "Do you want to record this meeting?" : "Still in this meeting?" });
export const extendedEnd = (previousEnd: number, now: number) => Math.max(previousEnd,now)+15*60_000;
export const missedCountdown = (lastTick: number, now: number) => now-lastTick > 10_000;
export const pruneDecisions = (decisions: Record<string,number>, now: number) => Object.fromEntries(Object.entries(decisions).filter(([,end]) => end > now-7*86400_000));
export function allowOccurrence(id: string, skipped: Record<string,number>, handled: Record<string,number>) {
  if (!(id in skipped)) return { skipped, handled };
  return { skipped: Object.fromEntries(Object.entries(skipped).filter(([k]) => k !== id)), handled: Object.fromEntries(Object.entries(handled).filter(([k]) => k !== id)) };
}
/** An unattended start must never enable live uploads; summarize is captured at start. */
export const startOptions = (settings: CalendarPolicySettings, automatic: boolean) => ({ microphone: true, systemAudio: true, summarizeOnStop: settings.calendarSummarize, liveTranscription: !automatic && settings.meetingLiveTranscription });
