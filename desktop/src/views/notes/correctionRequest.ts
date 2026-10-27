export interface CorrectionRequest { requestId: string; heard: string; replacement: string }
export interface CorrectionResult { requestId: string; error?: string }
export interface CorrectionTransport {
  subscribe: (handler: (result: CorrectionResult) => void) => Promise<() => void>;
  send: (request: CorrectionRequest) => Promise<void>;
}

/** Subscribe before sending, and resolve only after root confirms the settings write. */
export function requestCorrectionSave(request: CorrectionRequest, transport: CorrectionTransport, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    let settled = false;
    let unlisten: (() => void) | undefined;
    const finish = (success: boolean, error?: unknown) => {
      if (settled) return;
      settled = true;
      signal.removeEventListener("abort", abort);
      unlisten?.();
      if (success) resolve(); else reject(error);
    };
    const abort = () => finish(false, new Error("Correction request cancelled."));
    signal.addEventListener("abort", abort, { once: true });
    if (signal.aborted) { abort(); return; }
    void (async () => {
      unlisten = await transport.subscribe(result => {
        if (result.requestId !== request.requestId) return;
        if (result.error !== undefined) finish(false, new Error(result.error || "Could not save the correction."));
        else finish(true);
      });
      if (settled) { unlisten(); return; }
      await transport.send(request);
    })().catch(error => finish(false, error));
  });
}
