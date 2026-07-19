const DEFAULTS = Object.freeze({
  testnet: Object.freeze({
    mirror: "https://testnet.mirrornode.hedera.com",
    topic: "0.0.9585069",
  }),
  mainnet: Object.freeze({
    mirror: "https://mainnet-public.mirrornode.hedera.com",
    topic: null,
  }),
});

const CERTIFICATE_KEYS = Object.freeze([
  "v", "cert_id", "model_id", "model_hash", "designer", "license_type",
  "unit_serial", "buyer_hint", "payment_tx", "issued_at", "terms_hash",
]);

export class VerificationError extends Error {
  constructor(message, code = "verification_failed") {
    super(message);
    this.name = "VerificationError";
    this.code = code;
  }
}

export async function verify(input, {
  network = "testnet",
  mirror,
  topic,
  fetch: fetchImplementation = globalThis.fetch,
  timeoutMs = 10_000,
} = {}) {
  if (!DEFAULTS[network]) throw new VerificationError("network must be testnet or mainnet", "invalid_input");
  if (typeof fetchImplementation !== "function") {
    throw new VerificationError("a fetch implementation is required", "invalid_input");
  }

  const parsed = parseInput(input);
  if (parsed.messageUrl) {
    const expected = messageLocation(parsed.messageUrl);
    const envelope = await fetchJson(parsed.messageUrl, { fetchImplementation, timeoutMs });
    return verifiedResult(envelope, expected);
  }

  const mirrorBase = normalizedMirror(mirror || DEFAULTS[network].mirror);
  const topicId = topic || DEFAULTS[network].topic;
  if (!topicId) throw new VerificationError("--topic is required for this network", "invalid_input");
  requireEntityId(topicId, "topic");

  let pageUrl = new URL(`/api/v1/topics/${topicId}/messages?limit=100&order=desc`, mirrorBase);
  const visitedPages = new Set();
  while (pageUrl) {
    if (visitedPages.has(pageUrl.href)) {
      throw new VerificationError("mirror pagination repeated a page", "invalid_mirror_response");
    }
    visitedPages.add(pageUrl.href);
    const body = await fetchJson(pageUrl, { fetchImplementation, timeoutMs });
    if (!Array.isArray(body.messages)) {
      throw new VerificationError("mirror response has no messages array", "invalid_mirror_response");
    }

    for (const envelope of body.messages) {
      const decoded = decodePayload(envelope.message);
      if (decoded?.cert_id !== parsed.certId) continue;
      return verifiedResult(envelope, { topicId, certId: parsed.certId });
    }
    pageUrl = nextPage(body.links?.next, mirrorBase);
  }

  throw new VerificationError(`${parsed.certId} was not found on topic ${topicId}`, "certificate_not_found");
}

export function validateCertificate(certificate) {
  const errors = [];
  if (!plainObject(certificate)) return [ "certificate must be a JSON object" ];

  const missing = CERTIFICATE_KEYS.filter((key) => !Object.hasOwn(certificate, key));
  const extra = Object.keys(certificate).filter((key) => !CERTIFICATE_KEYS.includes(key));
  if (missing.length) errors.push(`missing fields: ${missing.join(", ")}`);
  if (extra.length) errors.push(`unknown fields: ${extra.join(", ")}`);
  if (certificate.v !== 1) errors.push("v must equal 1");
  if (!/^pw-[0-9]{6,}$/.test(certificate.cert_id)) errors.push("cert_id must match pw-NNNNNN");
  if (!positiveInteger(certificate.model_id)) errors.push("model_id must be a positive integer");
  if (!sha256(certificate.model_hash)) errors.push("model_hash must be sha256:<64 lowercase hex>");
  if (!entityId(certificate.designer)) errors.push("designer must be a Hedera account id");
  if (![ "personal", "commercial_unit" ].includes(certificate.license_type)) {
    errors.push("license_type must be personal or commercial_unit");
  }
  if (!positiveInteger(certificate.unit_serial)) errors.push("unit_serial must be a positive integer");
  if (!(certificate.buyer_hint === "bearer" || entityId(certificate.buyer_hint))) {
    errors.push("buyer_hint must be bearer or a Hedera account id");
  }
  if (!/^[0-9]+\.[0-9]+\.[0-9]+@[0-9]+\.[0-9]{1,9}$/.test(certificate.payment_tx)) {
    errors.push("payment_tx must be a Hedera transaction id");
  }
  if (typeof certificate.issued_at !== "string" ||
      !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/.test(certificate.issued_at) ||
      Number.isNaN(Date.parse(certificate.issued_at))) {
    errors.push("issued_at must be an RFC 3339 UTC timestamp");
  }
  if (!sha256(certificate.terms_hash)) errors.push("terms_hash must be sha256:<64 lowercase hex>");
  return errors;
}

function parseInput(input) {
  const value = String(input || "").trim();
  if (/^pw-[0-9]{6,}$/.test(value)) return { certId: value };

  let url;
  try {
    url = new URL(value);
  } catch {
    throw new VerificationError("input must be a pw-NNNNNN certificate id or URL", "invalid_input");
  }
  requireSafeProtocol(url);
  if (messageLocation(url)) return { messageUrl: url };

  const certId = url.pathname.split("/").find((part) => /^pw-[0-9]{6,}$/.test(part));
  if (certId) return { certId };
  throw new VerificationError("URL contains neither a certificate id nor an exact mirror message", "invalid_input");
}

function messageLocation(url) {
  const match = url.pathname.match(/^\/api\/v1\/topics\/(\d+\.\d+\.\d+)\/messages\/(\d+)\/?$/);
  if (!match) return null;
  return { topicId: match[1], sequenceNumber: Number(match[2]) };
}

function verifiedResult(envelope, expected) {
  if (!plainObject(envelope)) {
    throw new VerificationError("mirror message must be a JSON object", "invalid_mirror_response");
  }
  if (envelope.topic_id !== expected.topicId) {
    throw new VerificationError("mirror topic does not match the requested topic", "location_mismatch");
  }
  if (expected.sequenceNumber !== undefined && envelope.sequence_number !== expected.sequenceNumber) {
    throw new VerificationError("mirror sequence does not match the requested sequence", "location_mismatch");
  }
  if (!positiveInteger(envelope.sequence_number)) {
    throw new VerificationError("mirror sequence_number must be a positive integer", "invalid_mirror_response");
  }
  if (!/^\d+\.\d{9}$/.test(envelope.consensus_timestamp)) {
    throw new VerificationError("mirror consensus_timestamp is invalid", "invalid_mirror_response");
  }

  const certificate = decodePayload(envelope.message);
  if (!certificate) throw new VerificationError("mirror message is not base64 PWC-1 JSON", "invalid_certificate");
  const errors = validateCertificate(certificate);
  if (errors.length) throw new VerificationError(errors.join("; "), "invalid_certificate");
  if (expected.certId && certificate.cert_id !== expected.certId) {
    throw new VerificationError("certificate id does not match the requested id", "location_mismatch");
  }

  return Object.freeze({
    verified: true,
    standard: "PWC-1",
    certificate: Object.freeze(certificate),
    topic_id: envelope.topic_id,
    sequence_number: envelope.sequence_number,
    consensus_timestamp: envelope.consensus_timestamp,
  });
}

function decodePayload(encoded) {
  if (typeof encoded !== "string" || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(encoded)) {
    return null;
  }
  try {
    const bytes = Buffer.from(encoded, "base64");
    if (bytes.toString("base64") !== encoded) return null;
    const value = JSON.parse(bytes.toString("utf8"));
    return plainObject(value) ? value : null;
  } catch {
    return null;
  }
}

async function fetchJson(url, { fetchImplementation, timeoutMs }) {
  let response;
  try {
    response = await fetchImplementation(url, {
      headers: { accept: "application/json" },
      redirect: "error",
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch (error) {
    throw new VerificationError(`mirror request failed: ${error.message}`, "mirror_unavailable");
  }
  if (!response.ok) throw new VerificationError(`mirror returned HTTP ${response.status}`, "mirror_unavailable");
  const text = await response.text();
  if (text.length > 1_048_576) throw new VerificationError("mirror response is too large", "invalid_mirror_response");
  try {
    return JSON.parse(text);
  } catch {
    throw new VerificationError("mirror returned invalid JSON", "invalid_mirror_response");
  }
}

function normalizedMirror(value) {
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new VerificationError("mirror must be an absolute URL", "invalid_input");
  }
  requireSafeProtocol(url);
  url.pathname = "/";
  url.search = "";
  url.hash = "";
  return url;
}

function nextPage(next, mirrorBase) {
  if (!next) return null;
  const url = new URL(next, mirrorBase);
  if (url.origin !== mirrorBase.origin || !url.pathname.startsWith("/api/v1/topics/")) {
    throw new VerificationError("mirror pagination link left the mirror origin", "invalid_mirror_response");
  }
  return url;
}

function requireSafeProtocol(url) {
  const loopback = [ "localhost", "127.0.0.1", "::1" ].includes(url.hostname);
  if (url.protocol !== "https:" && !(url.protocol === "http:" && loopback)) {
    throw new VerificationError("mirror URLs must use HTTPS", "invalid_input");
  }
}

function requireEntityId(value, label) {
  if (!entityId(value)) throw new VerificationError(`${label} must be a Hedera entity id`, "invalid_input");
}

function plainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function positiveInteger(value) {
  return Number.isSafeInteger(value) && value > 0;
}

function entityId(value) {
  return typeof value === "string" && /^\d+\.\d+\.\d+$/.test(value);
}

function sha256(value) {
  return typeof value === "string" && /^sha256:[0-9a-f]{64}$/.test(value);
}
