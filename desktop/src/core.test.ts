import { describe, expect, it } from "vitest";
import { parseICS } from "./ics";
import { friendlyError } from "./native";
import { applyCorrections, expandSnippet, noteTitle } from "./text";

describe("portable OpenScribe core", () => {
  it("expands snippets only for a complete utterance", () => {
    const snippets = [{ id: "1", trigger: "my signature", replacement: "Regards,\nAlex" }];
    expect(expandSnippet(" My signature. ", snippets)).toBe("Regards,\nAlex");
    expect(expandSnippet("Please add my signature", snippets)).toBeUndefined();
  });

  it("applies longest corrections without replacing parts of words", () => {
    const rules = [
      { id: "1", heard: "open scribe", replacement: "OpenScribe" },
      { id: "2", heard: "scribe", replacement: "Scribe" }
    ];
    expect(applyCorrections("open scribe is ready", rules)).toBe("OpenScribe is ready");
    expect(applyCorrections("description", rules)).toBe("description");
  });

  it("creates stable short note titles", () => {
    expect(noteTitle("A useful first sentence. More detail.")).toBe("A useful first sentence");
    expect(noteTitle("   ")).toBe("Untitled note");
  });

  it("imports unfolded ICS events", () => {
    const events = parseICS("BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:one\nSUMMARY:Planning\\, review\nDTSTART:20260914T090000Z\nDTEND:20260914T100000Z\nURL:https://meet.example/one\nEND:VEVENT\nEND:VCALENDAR");
    expect(events).toHaveLength(1);
    expect(events[0].title).toBe("Planning, review");
    expect(events[0].start).toBe("2026-09-14T09:00:00Z");
  });

  it("never displays raw provider output in a notice", () => {
    expect(friendlyError("Provider request failed (HTTP 400): internal model trace")).toBe("The provider couldn’t complete this request. Please try again.");
    expect(friendlyError("The provider returned an unreadable response.")).toBe("That result wasn’t usable. Please try again.");
  });
});
