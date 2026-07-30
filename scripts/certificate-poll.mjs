import { PrintwrightError } from "@printwright/client";

const ANCHORED_STATUSES = new Set([ "anchored", "sandbox" ]);

export async function waitForCertificate({
  verify,
  certId,
  attempts = 11,
  delay = () => new Promise((resolve) => setTimeout(resolve, 2000)),
  onWait = () => {},
}) {
  let lastCertificate;
  let lastError;

  for (let attempt = 0; attempt < attempts; attempt++) {
    try {
      lastCertificate = await verify(certId);
      lastError = undefined;
      if (ANCHORED_STATUSES.has(lastCertificate.status)) return lastCertificate;
    } catch (error) {
      if (!retryableVerificationError(error)) throw error;
      lastError = error;
    }

    if (attempt === 0) onWait();
    if (attempt < attempts - 1) await delay();
  }

  if (lastCertificate) return lastCertificate;
  throw lastError;
}

export function retryableVerificationError(error) {
  if (!(error instanceof PrintwrightError)) return false;
  return error.status === undefined || error.status === 429 || error.status >= 500;
}
