import { createHash } from "node:crypto";

// Printwright certificate verifier. Certificates are anchored to Hedera as an
// opaque commitment — SHA-256( DOMAIN || nonce || JCS(certificate) ) — so the
// public topic reveals nothing. A holder proves a certificate by presenting a
// self-contained proof bundle (the certificate + blinding nonce + terms + where
// it is anchored); this library recomputes the commitment locally and confirms
// it equals the on-chain envelope, trusting neither Printwright's servers nor
// its verdict. What Hedera proves is timing + integrity of the committed bytes,
// NOT that every assertion inside the certificate is true — see `checks`.

const ALGORITHM = "sha256-jcs-v1";
const ENVELOPE_TYPE = "printwright-license-commitment";
const DOMAIN = Buffer.from("printwright:license-certificate:v1\0", "utf8");

// The bundle says where its commitment is anchored, but never where to look:
// the mirror host is one of these, and the message URL is derived from the
// topic id and sequence number. A bundle that could name its own "mirror"
// would be a bundle that verifies itself.
const MIRRORS = Object.freeze({
  testnet: "https://testnet.mirrornode.hedera.com",
  mainnet: "https://mainnet-public.mirrornode.hedera.com",
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

// RFC 8785 JSON Canonicalization Scheme — the reference implementation by the
// spec author (github.com/cyberphone/json-canonicalization). Vendored so this
// verifier keeps zero runtime dependencies. Must produce byte-identical output
// to the Ruby anchoring side; the shared test vector in test/ guarantees it.
export function canonicalize(object) {
  if (object === null || typeof object !== "object" || object.toJSON != null) {
    return JSON.stringify(object);
  }
  if (Array.isArray(object)) {
    return `[${object.map(canonicalize).join(",")}]`;
  }
  const members = Object.keys(object).sort().map(
    (key) => `${JSON.stringify(key)}:${canonicalize(object[key])}`,
  );
  return `{${members.join(",")}}`;
}

export function computeCommitment(certificate, nonceHex) {
  if (!/^[0-9a-f]+$/i.test(String(nonceHex)) || nonceHex.length % 2 !== 0) {
    throw new VerificationError("blinding_nonce must be hex", "invalid_input");
  }
  const preimage = Buffer.concat([
    DOMAIN,
    Buffer.from(nonceHex, "hex"),
    Buffer.from(canonicalize(certificate), "utf8"),
  ]);
  return createHash("sha256").update(preimage).digest("hex");
}

export function sha256Prefixed(text) {
  return `sha256:${createHash("sha256").update(Buffer.from(String(text), "utf8")).digest("hex")}`;
}

export function validateCertificate(certificate) {
  const errors = [];
  if (!plainObject(certificate)) return [ "certificate must be a JSON object" ];

  const missing = CERTIFICATE_KEYS.filter((key) => !Object.hasOwn(certificate, key));
  const extra = Object.keys(certificate).filter((key) => !CERTIFICATE_KEYS.includes(key));
  if (missing.length) errors.push(`missing fields: ${missing.join(", ")}`);
  if (extra.length) errors.push(`unknown fields: ${extra.join(", ")}`);
  if (certificate.v !== 1) errors.push("v must equal 1");
  if (!/^(sandbox-)?pw-[0-9a-f]{16,}$/.test(String(certificate.cert_id))) {
    errors.push("cert_id must be an unguessable pw- token");
  }
  if (!positiveInteger(certificate.model_id)) errors.push("model_id must be a positive integer");
  if (!sha256(certificate.model_hash)) errors.push("model_hash must be sha256:<64 lowercase hex>");
  // A stable studio id — never a wallet (privacy: the payout account is not published).
  if (!positiveInteger(certificate.designer)) errors.push("designer must be a positive integer studio id");
  if (![ "personal", "commercial_unit" ].includes(certificate.license_type)) {
    errors.push("license_type must be personal or commercial_unit");
  }
  if (!positiveInteger(certificate.unit_serial)) errors.push("unit_serial must be a positive integer");
  if (!(certificate.buyer_hint === "bearer" || entityId(certificate.buyer_hint) ||
        /^sandbox-buyer$/.test(String(certificate.buyer_hint)))) {
    errors.push("buyer_hint must be bearer or a Hedera account id");
  }
  if (!/^(sandbox-tx-[0-9a-f]+|[0-9]+\.[0-9]+\.[0-9]+@[0-9]+\.[0-9]{1,9})$/.test(String(certificate.payment_tx))) {
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

// Verify a proof bundle. Returns a frozen result whose `checks` separate what
// the ledger genuinely proves from what it does not.
export async function verifyBundle(bundle, {
  fetch: fetchImplementation = globalThis.fetch,
  expectedTopicId = null,
  timeoutMs = 10_000,
} = {}) {
  if (!plainObject(bundle)) throw new VerificationError("proof bundle must be a JSON object", "invalid_input");
  if (bundle.algorithm !== ALGORITHM) {
    throw new VerificationError(`unsupported algorithm: ${bundle.algorithm}`, "invalid_input");
  }
  const certificate = bundle.certificate;
  const nonce = bundle.blinding_nonce;
  if (!plainObject(certificate) || typeof nonce !== "string") {
    throw new VerificationError("bundle must carry a certificate and blinding_nonce", "invalid_input");
  }

  const checks = {};

  // 1. The bundle is internally consistent: its own commitment recomputes.
  const recomputed = computeCommitment(certificate, nonce);
  checks.bundle_integrity = recomputed === bundle.commitment ? "verified" : "failed";

  // 2. The certificate has the expected shape.
  const certErrors = validateCertificate(certificate);
  checks.certificate_schema = certErrors.length === 0 ? "verified" : "failed";

  // 3. The terms bytes in the bundle are exactly what the certificate commits to.
  const terms = plainObject(bundle.terms) ? bundle.terms : null;
  if (terms && typeof terms.text === "string") {
    const termsOk = sha256Prefixed(terms.text) === terms.hash && terms.hash === certificate.terms_hash;
    checks.terms_integrity = termsOk ? "verified" : "failed";
  } else {
    checks.terms_integrity = "unchecked";
  }

  // 4. The commitment is anchored on Hedera: fetch the on-chain envelope and
  //    confirm it is our commitment type and equals the recomputed value.
  const hedera = plainObject(bundle.hedera) ? bundle.hedera : {};
  let consensusTimestamp = null;
  let mirrorUrl = null;
  if (hedera.status === "minting" || !hedera.topic_id) {
    checks.hedera_anchoring = "pending";
  } else if (expectedTopicId && String(hedera.topic_id) !== expectedTopicId) {
    // Anchored somewhere the caller does not trust — no fetch, no verdict.
    checks.hedera_anchoring = "failed";
  } else {
    mirrorUrl = mirrorMessageUrl(hedera);
    const envelope = await fetchMirrorMessage(mirrorUrl, { fetchImplementation, timeoutMs });
    const onchain = decodeMessage(envelope.message);
    if (!onchain || onchain.type !== ENVELOPE_TYPE) {
      checks.hedera_anchoring = "failed";
    } else {
      checks.hedera_anchoring = onchain.commitment === recomputed ? "verified" : "failed";
      consensusTimestamp = envelope.consensus_timestamp ?? null;
    }
  }

  // 5. Hedera cannot vouch for the truth of the assertions inside the cert
  //    (issuer authority, physical print) — only that these bytes were
  //    committed no later than the consensus timestamp.
  checks.issuer_assertions = "not_independently_proven";

  const verified = checks.bundle_integrity === "verified" &&
    checks.certificate_schema === "verified" &&
    checks.hedera_anchoring === "verified" &&
    checks.terms_integrity !== "failed";

  return Object.freeze({
    verified,
    cert_id: certificate.cert_id,
    commitment: recomputed,
    checks: Object.freeze(checks),
    certificate_errors: Object.freeze(certErrors),
    topic_id: hedera.topic_id ?? null,
    sequence_number: hedera.sequence_number ?? null,
    consensus_timestamp: consensusTimestamp,
    mirror_url: mirrorUrl,
  });
}

function mirrorMessageUrl(hedera) {
  const network = hedera.network ?? "testnet";
  if (!Object.hasOwn(MIRRORS, network)) {
    throw new VerificationError(
      `no public mirror for network "${network}" — only ${Object.keys(MIRRORS).join(" and ")} can be verified`,
      "invalid_input",
    );
  }
  if (!/^\d+\.\d+\.\d+$/.test(String(hedera.topic_id))) {
    throw new VerificationError("topic_id must be a Hedera entity id", "invalid_input");
  }
  if (!positiveInteger(hedera.sequence_number)) {
    throw new VerificationError("sequence_number must be a positive integer", "invalid_input");
  }
  return `${MIRRORS[network]}/api/v1/topics/${hedera.topic_id}/messages/${hedera.sequence_number}`;
}

async function fetchMirrorMessage(url, { fetchImplementation, timeoutMs }) {
  const parsed = safeUrl(url);
  const envelope = await fetchJson(parsed, { fetchImplementation, timeoutMs });
  if (!plainObject(envelope)) {
    throw new VerificationError("mirror message must be a JSON object", "invalid_mirror_response");
  }
  return envelope;
}

function decodeMessage(encoded) {
  if (typeof encoded !== "string" ||
      !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(encoded)) {
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
  if (typeof fetchImplementation !== "function") {
    throw new VerificationError("a fetch implementation is required", "invalid_input");
  }
  // Own the timeout timer so it is always cleared — a dangling AbortSignal
  // timer would keep the process alive after the request resolves.
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  let response;
  try {
    response = await fetchImplementation(url, {
      headers: { accept: "application/json" },
      redirect: "error",
      signal: controller.signal,
    });
  } catch (error) {
    throw new VerificationError(`mirror request failed: ${error.message}`, "mirror_unavailable");
  } finally {
    clearTimeout(timer);
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

function safeUrl(value) {
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new VerificationError("mirror URL is invalid", "invalid_input");
  }
  const loopback = [ "localhost", "127.0.0.1", "::1" ].includes(url.hostname);
  if (url.protocol !== "https:" && !(url.protocol === "http:" && loopback)) {
    throw new VerificationError("mirror URLs must use HTTPS", "invalid_input");
  }
  return url;
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
