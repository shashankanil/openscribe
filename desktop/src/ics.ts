import type { CalendarEvent } from "./types";

function unfold(value: string) { return value.replace(/\r?\n[ \t]/g, ""); }
function field(block: string, name: string) {
  const match = block.match(new RegExp(`^${name}(?:;[^:]*)?:(.*)$`, "mi"));
  return match?.[1]?.trim().replace(/\\n/g, "\n").replace(/\\,/g, ",");
}
function date(value?: string) {
  if (!value) return new Date().toISOString();
  if (/^\d{8}$/.test(value)) return `${value.slice(0,4)}-${value.slice(4,6)}-${value.slice(6,8)}T00:00:00`;
  const match = value.match(/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z?)$/);
  return match ? `${match[1]}-${match[2]}-${match[3]}T${match[4]}:${match[5]}:${match[6]}${match[7]}` : new Date(value).toISOString();
}

export function parseICS(contents: string): CalendarEvent[] {
  return unfold(contents).split("BEGIN:VEVENT").slice(1).map((block) => ({
    id: field(block, "UID") ?? crypto.randomUUID(),
    title: field(block, "SUMMARY") ?? "Calendar event",
    start: date(field(block, "DTSTART")),
    end: date(field(block, "DTEND")),
    location: field(block, "LOCATION"),
    url: field(block, "URL")
  })).sort((a, b) => a.start.localeCompare(b.start));
}
