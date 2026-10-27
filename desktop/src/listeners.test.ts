import { expect, it, vi } from "vitest";
import { ListenerScope } from "./listeners";

it("removes listeners even when registration resolves after React cleanup", async () => {
  let resolve!: (unlisten: () => void) => void;
  const pending = new Promise<() => void>(done => { resolve = done; });
  const scope = new ListenerScope(), unlisten = vi.fn();
  scope.add(pending, error => { throw error; }); scope.dispose(); resolve(unlisten);
  await pending; await Promise.resolve();
  expect(unlisten).toHaveBeenCalledOnce();
});
