import type { CaptureReadiness } from "./settingsSupport";
import { canPractice } from "./settingsSupport";
/** Both results must be fresh; an emitted recording intent is not evidence of access. */
export async function readSetupReadiness(paste: boolean, checkKey: () => Promise<boolean>, checkCapture: () => Promise<CaptureReadiness>) {
  const [hasKey, readiness] = await Promise.all([checkKey(), checkCapture()]);
  return { hasKey, readiness, ready: canPractice(readiness, hasKey, paste) };
}
