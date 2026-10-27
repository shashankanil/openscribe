import { it, expect } from "vitest";
import { parseAccelerator, defaultBindings, validateBindings, ShortcutInterpreter, shortcutActions, assignShortcut, dictationHint, rightCtrlBinding, bindingFromKey } from "./shortcuts";
it("normalizes modifier aliases and display", () => {
  expect(parseAccelerator("shift+control+alt+v")).toEqual({accelerator:"Ctrl+Alt+Shift+V",display:"Ctrl Alt Shift V"});
  expect(parseAccelerator("CmdOrCtrl+Space").accelerator).toBe("Ctrl+Space");
  expect(parseAccelerator("Alt+F12").accelerator).toBe("Alt+F12");
});
it("rejects invalid keys, conflicts and Windows reserved combinations", () => {
  for (const key of ["Alt+Space","Win+M","Ctrl++A","Ctrl+Ctrl+A","Ctrl+A+B","A","Ctrl","Ctrl+Potato","Alt+F4","Alt+Tab","Ctrl+Alt+Delete"]) expect(() => parseAccelerator(key),key).toThrow();
  expect(() => validateBindings({dictate:parseAccelerator("Ctrl+Alt+M"),meeting:{accelerator:"Alt+Control+M",display:""}})).toThrow(/same shortcut/);
  expect(() => validateBindings(defaultBindings)).not.toThrow(); expect(Object.keys(defaultBindings).sort()).toEqual([...shortcutActions].sort());
});
it("tap toggles recording; hold releases after exactly 350ms", () => {
  const keys = new ShortcutInterpreter();
  expect(keys.handle("dictate","pressed",0,false)).toEqual(["startDictation"]);
  expect(keys.handle("dictate","pressed",10,true)).toEqual([]);
  expect(keys.handle("dictate","released",349,true)).toEqual([]);
  expect(keys.handle("dictate","pressed",500,true)).toEqual(["finishDictation"]);
  expect(keys.handle("dictate","released",1000,false)).toEqual([]);
  expect(keys.handle("dictate","pressed",2000,false)).toEqual(["startDictation"]);
  expect(keys.handle("dictate","released",2350,true)).toEqual(["finishDictation"]);
});
it("push to talk handles release during startup and ignores unrelated releases", () => {
  const keys = new ShortcutInterpreter();
  expect(keys.handle("holdToTalk","released",0,false)).toEqual([]);
  expect(keys.handle("holdToTalk","pressed",0,false)).toEqual(["startDictation"]);
  expect(keys.handle("holdToTalk","released",10,false)).toEqual(["finishDictation"]);
  expect(keys.handle("dictate","pressed",0,false,true)).toEqual([]);
  keys.reset(); expect(keys.handle("dictate","released",1000,false)).toEqual([]);
  for (const action of shortcutActions.slice(2)) {
    expect(keys.handle(action,"pressed",0,false)).toEqual([action]); expect(keys.handle(action,"released",1,false)).toEqual([]);
  }
});
it("assigning a taken shortcut moves it, as on macOS, and removing clears only that action", () => {
  const moved = assignShortcut(defaultBindings, "meeting", parseAccelerator("Ctrl+Alt+Space"));
  expect(moved.displaced).toBe("dictate");
  expect(moved.bindings.dictate).toBeUndefined();
  expect(moved.bindings.meeting?.accelerator).toBe("Ctrl+Alt+Space");
  expect(() => validateBindings(moved.bindings)).not.toThrow();
  const fresh = assignShortcut(defaultBindings, "meeting", parseAccelerator("Ctrl+Shift+F9"));
  expect(fresh.displaced).toBeUndefined();
  const removed = assignShortcut(defaultBindings, "pasteLast", null);
  expect(removed.bindings.pasteLast).toBeUndefined();
  expect(removed.bindings.dictate).toEqual(defaultBindings.dictate);
});
it("the dictation hint falls back to push to talk and hides keys another app holds", () => {
  expect(dictationHint(defaultBindings)).toBe("Ctrl Alt Space");
  expect(dictationHint(defaultBindings, ["dictate"])).toBeNull();
  expect(dictationHint({ holdToTalk: parseAccelerator("Ctrl+Alt+H") })).toBe("Ctrl Alt H");
  expect(dictationHint({})).toBeNull();
});
it("Right Ctrl alone is for dictation only, and a Ctrl combination cancels only what it started", () => {
  expect(() => validateBindings({ holdToTalk: rightCtrlBinding })).not.toThrow();
  expect(() => validateBindings({ meeting: rightCtrlBinding })).toThrow(/dictation/);
  expect(() => validateBindings({ dictate: rightCtrlBinding, holdToTalk: rightCtrlBinding })).toThrow(/same shortcut/);
  const keys = new ShortcutInterpreter();
  expect(keys.handle("holdToTalk","pressed",0,false)).toEqual(["startDictation"]);
  expect(keys.handle("holdToTalk","cancelled",50,true)).toEqual(["cancelDictation"]);
  expect(keys.handle("holdToTalk","released",60,false)).toEqual([]);
  expect(keys.handle("dictate","pressed",100,false)).toEqual(["startDictation"]);
  expect(keys.handle("dictate","released",150,true)).toEqual([]);
  // A later Ctrl combination must not discard a dictation the key did not just start.
  expect(keys.handle("dictate","pressed",900,true)).toEqual(["finishDictation"]);
  expect(keys.handle("dictate","cancelled",950,false)).toEqual([]);
  expect(keys.handle("holdToTalk","pressed",2000,false)).toEqual(["startDictation"]);
  expect(keys.handle("holdToTalk","released",2600,true)).toEqual(["finishDictation"]);
});
it("records physical keys, including punctuation, and refuses Shift alone on typing keys", () => {
  const press = (code: string, key: string, mods: Partial<{ ctrlKey: boolean; altKey: boolean; shiftKey: boolean; metaKey: boolean }> = {}) =>
    bindingFromKey({ code, key, ctrlKey: false, altKey: false, shiftKey: false, metaKey: false, ...mods });
  expect(press("Comma", ",", { ctrlKey: true, altKey: true })).toEqual({ accelerator: "Ctrl+Alt+Comma", display: "Ctrl Alt ," });
  expect(press("Slash", "?", { ctrlKey: true, shiftKey: true })).toEqual({ accelerator: "Ctrl+Shift+Slash", display: "Ctrl Shift /" });
  expect(press("KeyQ", "a", { altKey: true })?.accelerator).toBe("Alt+Q");
  expect(press("Space", " ", { ctrlKey: true })?.accelerator).toBe("Ctrl+Space");
  expect(press("ControlRight", "Control", { ctrlKey: true })).toBeNull();
  expect(() => press("KeyA", "A", { shiftKey: true })).toThrow(/Ctrl or Alt/);
  expect(() => press("ArrowUp", "ArrowUp", { shiftKey: true })).toThrow(/Ctrl or Alt/);
  expect(press("F9", "F9", { shiftKey: true })?.accelerator).toBe("Shift+F9");
  expect(() => press("KeyA", "a")).toThrow();
});
