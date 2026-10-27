import { describe, expect, it } from "vitest";
import type { CalendarEvent } from "../../api/parityTypes";
import { eventsOnDay, monthDays } from "./calendarAgendaHelpers";

const event = (start: Date, end: Date): CalendarEvent => ({ id: "event", title: "Meeting", start: start.toISOString(), end: end.toISOString(), calendarID: "work", calendarName: "Work", hasAttendees: true, excluded: false, isAllDay: false });

describe("calendar agenda", () => {
  it("includes overnight events but excludes events ending at the start of the day", () => {
    const overnight = event(new Date(2026, 9, 19, 23), new Date(2026, 9, 20, 1));
    const ended = event(new Date(2026, 9, 19, 22), new Date(2026, 9, 20));
    const tomorrow = event(new Date(2026, 9, 21), new Date(2026, 9, 21, 1));
    expect(eventsOnDay([ended, tomorrow, overnight], new Date(2026, 9, 20, 12))).toEqual([overnight]);
  });

  it("includes leap day and pads the month to complete weeks", () => {
    const days = monthDays(new Date(2024, 1, 29));
    expect(days.length % 7).toBe(0);
    expect(days.filter(Boolean)).toHaveLength(29);
    expect(days[4]?.getDate()).toBe(1);
    expect(days.filter(Boolean).at(-1)?.getDate()).toBe(29);
  });
});
