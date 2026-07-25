import { test } from "node:test";
import assert from "node:assert/strict";
import {
  canonicalize, computeCommitment, sha256Prefixed, validateCertificate, verifyBundle, VerificationError,
} from "../index.js";

// ---------------------------------------------------------------------------
// Cross-language interop lock. This exact (certificate, nonce) -> commitment
// triple is asserted identically in the Ruby anchoring suite
// (test/services/certificates/commitment_vector_test.rb). If RFC 8785 JCS or
// the commitment construction drifts between Ruby and JS, this fails first.
// ---------------------------------------------------------------------------
const VECTOR_CERT = {
  v: 1, cert_id: "pw-abc123", model_id: 7, model_hash: `sha256:${"a".repeat(64)}`,
  designer: 14, license_type: "personal", unit_serial: 3, buyer_hint: "bearer",
  payment_tx: "0.0.7@1.2", issued_at: "2026-07-25T00:00:00Z", terms_hash: `sha256:${"b".repeat(64)}`,
};
const VECTOR_NONCE = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";
const VECTOR_COMMITMENT = "2b523aa587fce40efab3395a2b074293eb2014cef5f82e844feb6e0a1df1e0fa";

test("cross-language commitment vector matches the Ruby anchoring side", () => {
  assert.equal(computeCommitment(VECTOR_CERT, VECTOR_NONCE), VECTOR_COMMITMENT);
});

test("JCS canonicalization sorts keys and is order-independent", () => {
  assert.equal(canonicalize({ b: 2, a: "x", v: 1 }), '{"a":"x","b":2,"v":1}');
  const shuffled = Object.fromEntries(Object.entries(VECTOR_CERT).reverse());
  assert.equal(computeCommitment(shuffled, VECTOR_NONCE), VECTOR_COMMITMENT);
});

test("commitment is nonce-sensitive", () => {
  assert.notEqual(computeCommitment(VECTOR_CERT, "ff".repeat(32)), VECTOR_COMMITMENT);
});

// ---------------------------------------------------------------------------
// Bundle verification
// ---------------------------------------------------------------------------
const TERMS_TEXT = "Printwright Personal Print License — v1\nRevealed in full.\n";
const CERT = {
  v: 1, cert_id: `pw-${"a1b2c3d4".repeat(3)}`, model_id: 7, model_hash: `sha256:${"a".repeat(64)}`,
  designer: 14, license_type: "personal", unit_serial: 3, buyer_hint: "0.0.9613501",
  payment_tx: "0.0.7162784@1784900288.288350505", issued_at: "2026-07-25T00:00:00Z",
  terms_hash: sha256Prefixed(TERMS_TEXT),
};
const NONCE = "ff".repeat(32);
const COMMITMENT = computeCommitment(CERT, NONCE);
const MIRROR_URL = "https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9585069/messages/57";

function anchoredBundle(overrides = {}) {
  return {
    proof_version: 1, algorithm: "sha256-jcs-v1", certificate: CERT, blinding_nonce: NONCE,
    commitment: COMMITMENT,
    terms: { version: "v1", kind: "personal", hash: CERT.terms_hash, text: TERMS_TEXT },
    hedera: {
      network: "testnet", topic_id: "0.0.9585069", sequence_number: 57, mirror_url: MIRROR_URL,
      hashscan_url: "https://hashscan.io/testnet/topic/0.0.9585069",
    },
    ...overrides,
  };
}

function mirrorReturning(commitment, { consensus = "1784900303.804467718" } = {}) {
  const message = Buffer.from(JSON.stringify({
    type: "printwright-license-commitment", version: 1, algorithm: "sha256-jcs-v1", commitment,
  })).toString("base64");
  return async () => ({ ok: true, text: async () => JSON.stringify({ message, consensus_timestamp: consensus }) });
}

test("valid bundle verifies against the on-chain commitment", async () => {
  const result = await verifyBundle(anchoredBundle(), { fetch: mirrorReturning(COMMITMENT) });
  assert.equal(result.verified, true);
  assert.equal(result.checks.bundle_integrity, "verified");
  assert.equal(result.checks.certificate_schema, "verified");
  assert.equal(result.checks.terms_integrity, "verified");
  assert.equal(result.checks.hedera_anchoring, "verified");
  assert.equal(result.checks.issuer_assertions, "not_independently_proven");
  assert.equal(result.consensus_timestamp, "1784900303.804467718");
});

test("a certificate the on-chain commitment does not cover fails anchoring", async () => {
  const result = await verifyBundle(anchoredBundle(), { fetch: mirrorReturning("dead".repeat(16)) });
  assert.equal(result.verified, false);
  assert.equal(result.checks.hedera_anchoring, "failed");
});

test("a tampered revealed certificate fails bundle integrity", async () => {
  const tampered = anchoredBundle({ certificate: { ...CERT, unit_serial: 999 } });
  const result = await verifyBundle(tampered, { fetch: mirrorReturning(COMMITMENT) });
  assert.equal(result.verified, false);
  assert.equal(result.checks.bundle_integrity, "failed");
});

test("terms text that does not hash to the committed terms_hash fails", async () => {
  const result = await verifyBundle(
    anchoredBundle({ terms: { version: "v1", kind: "personal", hash: CERT.terms_hash, text: "different terms" } }),
    { fetch: mirrorReturning(COMMITMENT) },
  );
  assert.equal(result.checks.terms_integrity, "failed");
  assert.equal(result.verified, false);
});

test("a minting bundle reports anchoring pending, not verified", async () => {
  const result = await verifyBundle(anchoredBundle({ hedera: { status: "minting" } }), { fetch: mirrorReturning(COMMITMENT) });
  assert.equal(result.checks.hedera_anchoring, "pending");
  assert.equal(result.verified, false);
});

test("validateCertificate accepts the privacy-preserving shape and rejects the old one", () => {
  assert.deepEqual(validateCertificate(CERT), []);
  assert.ok(validateCertificate({ ...CERT, designer: "0.0.5" }).length, "wallet-as-designer rejected");
  assert.ok(validateCertificate({ ...CERT, cert_id: "pw-000001" }).length, "sequential id rejected");
});

test("the mirror is derived from topic and sequence, never taken from the bundle", async () => {
  const hostile = anchoredBundle({
    hedera: {
      network: "testnet", topic_id: "0.0.9585069", sequence_number: 57,
      mirror_url: "https://mirror.attacker.example/api/v1/topics/0.0.9585069/messages/57",
    },
  });
  const requested = [];
  const fetchImplementation = async (url) => {
    requested.push(String(url));
    return { ok: true, text: async () => JSON.stringify({ message: Buffer.from(JSON.stringify({
      type: "printwright-license-commitment", version: 1, algorithm: "sha256-jcs-v1", commitment: COMMITMENT,
    })).toString("base64"), consensus_timestamp: "1784900303.804467718" }) };
  };

  const result = await verifyBundle(hostile, { fetch: fetchImplementation });

  assert.equal(result.verified, true);
  assert.deepEqual(requested, [ MIRROR_URL ]);
  assert.equal(result.mirror_url, MIRROR_URL);
});

test("a bundle anchored off the pinned topic fails without a mirror call", async () => {
  let called = false;
  const result = await verifyBundle(
    anchoredBundle({ hedera: { network: "testnet", topic_id: "0.0.4242", sequence_number: 1 } }),
    { expectedTopicId: "0.0.9585069", fetch: async () => { called = true; } },
  );
  assert.equal(result.checks.hedera_anchoring, "failed");
  assert.equal(result.verified, false);
  assert.equal(called, false);
});

test("a network with no public mirror cannot be verified", async () => {
  await assert.rejects(
    () => verifyBundle(
      anchoredBundle({ hedera: { network: "sandbox", topic_id: "0.0.1", sequence_number: 1 } }),
      { fetch: mirrorReturning(COMMITMENT) },
    ),
    VerificationError,
  );
});

test("unsupported algorithm is rejected", async () => {
  await assert.rejects(
    () => verifyBundle({ ...anchoredBundle(), algorithm: "md5" }, { fetch: mirrorReturning(COMMITMENT) }),
    VerificationError,
  );
});

// ---------------------------------------------------------------------------
// CLI: verifies a bundle from stdin using only the (mock) mirror
// ---------------------------------------------------------------------------
// The CLI is a thin I/O wrapper over verifyBundle (covered above); it is
// exercised end-to-end against a real proof bundle in the re-settle evidence
// run. Subprocess tests are omitted here — node:test + execFile stdin hangs the
// runner — and the wrapper is smoke-checked manually.
