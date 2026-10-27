import { describe, expect, it, vi } from "vitest";
import { requestCorrectionSave, type CorrectionResult, type CorrectionTransport } from "./correctionRequest";

const request = { requestId: "request-1", heard: "wrong", replacement: "right" };
function harness() {
  let receive: (result: CorrectionResult) => void = () => { throw new Error("Listener not installed"); };
  const unlisten = vi.fn();
  const transport: CorrectionTransport = {
    subscribe: vi.fn(async handler => { receive = handler; return unlisten; }),
    send: vi.fn(async () => {})
  };
  return { transport, unlisten, ack: (result: CorrectionResult) => receive(result) };
}

describe("correction persistence acknowledgment", () => {
  it("does not resolve on delivery or on another request's acknowledgment", async () => {
    const h = harness();
    const result = requestCorrectionSave(request, h.transport, new AbortController().signal);
    let saved = false; void result.then(() => { saved = true; });
    await Promise.resolve(); await Promise.resolve();
    expect(h.transport.send).toHaveBeenCalledWith(request);
    expect(saved).toBe(false);
    h.ack({ requestId: "different-request" }); await Promise.resolve();
    expect(saved).toBe(false); expect(h.unlisten).not.toHaveBeenCalled();
    h.ack({ requestId: request.requestId });
    await result; expect(saved).toBe(true); expect(h.unlisten).toHaveBeenCalledTimes(1);
  });

  it("installs the result listener before sending, including immediate acknowledgments", async () => {
    const h = harness();
    h.transport.send = vi.fn(async () => h.ack({ requestId: request.requestId }));
    await expect(requestCorrectionSave(request, h.transport, new AbortController().signal)).resolves.toBeUndefined();
    expect(h.unlisten).toHaveBeenCalledTimes(1);
  });

  it("rejects a failed settings write and permits a distinct retry without accepting a stale acknowledgment", async () => {
    const h = harness();
    const first = requestCorrectionSave(request, h.transport, new AbortController().signal);
    const failure = expect(first).rejects.toThrow("Disk is full");
    await Promise.resolve(); h.ack({ requestId: request.requestId, error: "Disk is full" }); await failure;
    const retry = { ...request, requestId: "retry-2" };
    const second = requestCorrectionSave(retry, h.transport, new AbortController().signal);
    let saved = false; void second.then(() => { saved = true; });
    await Promise.resolve(); h.ack({ requestId: request.requestId }); await Promise.resolve();
    expect(saved).toBe(false);
    h.ack({ requestId: retry.requestId }); await second;
    expect(h.unlisten).toHaveBeenCalledTimes(2);
  });

  it("surfaces listener setup failure without sending an unacknowledgeable request", async () => {
    const h = harness(); h.transport.subscribe = vi.fn(async () => { throw new Error("Listen failed"); });
    await expect(requestCorrectionSave(request, h.transport, new AbortController().signal)).rejects.toThrow("Listen failed");
    expect(h.transport.send).not.toHaveBeenCalled();
  });

  it("cleans up when delivery fails", async () => {
    const h = harness(); h.transport.send = vi.fn(async () => { throw new Error("Send failed"); });
    await expect(requestCorrectionSave(request, h.transport, new AbortController().signal)).rejects.toThrow("Send failed");
    expect(h.unlisten).toHaveBeenCalledTimes(1);
  });

  it("cleans up a listener that finishes registering after the dialog closes", async () => {
    const h = harness(); let ready!: (unlisten: () => void) => void;
    h.transport.subscribe = vi.fn(() => new Promise<() => void>(resolve => { ready = resolve; }));
    const controller = new AbortController();
    const result = requestCorrectionSave(request, h.transport, controller.signal);
    const cancelled = expect(result).rejects.toThrow("cancelled");
    controller.abort(); ready(h.unlisten); await cancelled; await Promise.resolve();
    expect(h.unlisten).toHaveBeenCalledTimes(1); expect(h.transport.send).not.toHaveBeenCalled();
  });
});
