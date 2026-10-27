import { describe, it, expect } from "vitest";
import type { NoteCapture, VoiceNote } from "./model";
import * as d from "./dailyNotes";
const capture = (id: string, text = id, extra: Partial<NoteCapture> = {}): NoteCapture => ({ id, createdAt: "2026-10-19T10:00:00Z", title: "", rawText: `raw ${id}`, text, duration: 2, ...extra });
const note = (extra: Partial<VoiceNote> = {}): VoiceNote => ({ id: "note", createdAt: "2026-10-19T10:00:00Z", title: "", rawText: "raw", cleanedText: "clean", duration: 2, isPinned: false, tags: [], source: "Dictation", ...extra });
describe("Swift daily note semantics", () => {
  it("retains explicit empty edits and empty daily text", () => {
    expect(d.displayText(note({editedText: ""}))).toBe("");
    expect(d.displayText(note({cleanedText: ""}))).toBe("raw");
    expect(d.displayText(note({cleanedText: "", captures: []}))).toBe("");
    expect(d.displayTitle(note({title: " Untitled note ", cleanedText: "\nhello   world\nmore"}))).toBe("hello world");
    expect(d.displayTitle(note({title: " named "}))).toBe("named");
    expect(d.displayTitle(note({cleanedText: "x".repeat(80)}))).toHaveLength(64);
  });
  it("appends sorted unique captures, recomputes sources and does not mutate", () => {
    const original = note({ captures: [capture("later", "later", {createdAt: "2026-10-19T12:00:00Z", sourceApplication: "Browser"})] });
    const updated = d.appendCaptures(original,[capture("earlier","earlier",{sourceApplication: "Editor"}),capture("later")]);
    expect(updated.captures?.map(c => c.id)).toEqual(["earlier","later"]);
    expect(updated.cleanedText).toBe("earlier\n\nlater"); expect(updated.duration).toBe(4);
    expect(updated.sourceApplication).toBeUndefined(); expect(original.captures).toHaveLength(1);
    expect(d.appendCaptures(updated,[capture("later")])).toBe(updated);
  });
  it("updates and removes while retaining superseded transcript and duration", () => {
    const n = d.recomputeFromCaptures(note({captures: [capture("a","hidden",{superseded:true}),capture("b","visible"),capture("c","written",{kind:"text"})]}));
    expect(n.rawText).toBe("raw a\n\nraw b"); expect(n.cleanedText).toBe("visible\n\nwritten"); expect(n.duration).toBe(6);
    expect(d.updateCapture(n,capture("b","")).cleanedText).toBe("written");
    expect(d.removeCapture(n,"b").cleanedText).toBe("written");
    expect(d.updateCapture(n,capture("missing"))).toBe(n);
  });
  it("merges new captures into a pending empty edit", () => {
    const pending = note({editedText:"",captures:[capture("a")]});
    const merged = d.mergingNewCaptures(pending,note({captures:[capture("a"),capture("b","arrived")]}));
    expect(merged.editedText).toBe("arrived"); expect(merged.captures).toHaveLength(2);
  });
  it("migrates old body edits to written entries preserving screenshot entries", () => {
    const original = note({editedText:"",captures:[capture("a"),capture("shot","",{kind:"screenshot"})]});
    const migrated = d.migratedToTimeline(original,() => "NEW-ID");
    expect(migrated.editedText).toBeUndefined(); expect(migrated.captures?.[0].superseded).toBe(true);
    expect(d.visibleCaptures(migrated).map(c => c.id)).toEqual(["shot","NEW-ID"]);
    expect(d.displayText(migrated)).toBe(""); expect(migrated.rawText).toBe("raw a\n\nraw shot");
  });
  it("paste last selects latest note by capture date, skips empty or superseded entries", () => {
    const daily = note({captures:[capture("a","recent",{createdAt:"2026-10-19T13:00:00Z"}),capture("shot","",{createdAt:"2026-10-19T14:00:00Z",kind:"screenshot"})]});
    expect(d.pasteLastText([daily,note({cleanedText:"older",createdAt:"2026-10-19T12:00:00Z"})])).toBe("recent");
    expect(d.latestText(note({captures:[capture("a","hidden",{superseded:true})]}))).toBe("clean");
    expect(d.pasteLastText([])).toBeUndefined();
  });
  it("groups by local calendar day and leaves manually written notes separate", () => {
    const first = note({id:"a",isPinned:true,tags:["a"]});
    const second = note({id:"b",createdAt:"2026-10-19T11:00:00Z",tags:["b"]});
    const manual = note({id:"manual",source:"Note"});
    const grouped = d.groupExistingDictations([second,manual,first]);
    expect(grouped).toHaveLength(2); const daily = grouped.find(d.isDailyNote)!;
    expect(daily.id).toBe("a"); expect(daily.tags).toEqual(["a","b"]); expect(daily.isPinned).toBe(true);
    expect(d.groupExistingDictations(grouped)).toEqual(grouped);
    expect(d.localDay(new Date(2026,9,19,23,59))).toBe("2026-10-19");
    expect(d.addCapture(grouped,capture("c"))).toHaveLength(2);
  });
  it("limits titles by Swift characters and recognizes Unicode newlines", () => {
    const family = "👨‍👩‍👧‍👦";
    expect(d.displayTitle(note({cleanedText:family.repeat(65)}))).toBe(family.repeat(64));
    expect(d.displayTitle(note({cleanedText:"first\u0085second"}))).toBe("first");
  });
  it("keeps captures on opposite sides of local midnight in different day notes", () => {
    const before = new Date(2026,9,19,23,59).toISOString();
    const after = new Date(2026,9,20,0,1).toISOString();
    const notes = d.addCapture(d.addCapture([],capture("before","before",{createdAt:before})),capture("after","after",{createdAt:after}));
    expect(notes).toHaveLength(2);
    expect(notes.map(n => n.id)).toEqual(["after","before"]);
  });
});
