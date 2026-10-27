import type { CalendarEvent } from "../../api/parityTypes";

export function eventsOnDay(events: CalendarEvent[], day: Date): CalendarEvent[] {
  const start = new Date(day.getFullYear(), day.getMonth(), day.getDate());
  const end = new Date(day.getFullYear(), day.getMonth(), day.getDate() + 1);
  return events.filter(event => Date.parse(event.start) < end.getTime() && Date.parse(event.end) > start.getTime())
    .sort((a, b) => Date.parse(a.start) - Date.parse(b.start));
}

export function monthDays(month: Date): (Date | null)[] {
  const start = new Date(month.getFullYear(), month.getMonth(), 1);
  const days: (Date | null)[] = Array.from({ length: start.getDay() }, () => null);
  const count = new Date(month.getFullYear(), month.getMonth() + 1, 0).getDate();
  for (let day = 1; day <= count; day++) days.push(new Date(month.getFullYear(), month.getMonth(), day));
  while (days.length % 7) days.push(null);
  return days;
}
