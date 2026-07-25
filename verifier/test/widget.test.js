import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";
import { sha256Prefixed } from "../index.js";

// The browser widget (public/printwright-verify-widget.js) is the third
// implementation of the same commitment scheme, next to Ruby (anchoring) and
// this package (CLI). It ships as a classic script for pages that cannot
// bundle, so it is tested here in a VM context with a fake window: the same
// cross-language vector must hold, or an embedded badge would disagree with
// the ledger.

const SOURCE = await readFile(new URL("../../public/printwright-verify-widget.js", import.meta.url), "utf8");

function loadWidget(fetchImpl) {
  const context = vm.createContext({
    crypto: globalThis.crypto,
    TextEncoder, TextDecoder, AbortController, setTimeout, clearTimeout,
    atob: globalThis.atob, btoa: globalThis.btoa,
    fetch: fetchImpl,
  });
  vm.runInContext(SOURCE, context);
  return context.PrintwrightVerify;
}

const VECTOR_CERT = {
  v: 1, cert_id: "pw-abc123", model_id: 7, model_hash: `sha256:${"a".repeat(64)}`,
  designer: 14, license_type: "personal", unit_serial: 3, buyer_hint: "bearer",
  payment_tx: "0.0.7@1.2", issued_at: "2026-07-25T00:00:00Z", terms_hash: `sha256:${"b".repeat(64)}`,
};
const VECTOR_NONCE = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";
const VECTOR_COMMITMENT = "2b523aa587fce40efab3395a2b074293eb2014cef5f82e844feb6e0a1df1e0fa";

const TERMS_TEXT = "Printwright Personal Print License — v1\nRevealed in full.\n";
const TERMS_HASH = sha256Prefixed(TERMS_TEXT);
const MIRROR_URL = "https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9585069/messages/57";

function mirrorReturning(commitment, requested = []) {
  return async (url) => {
    requested.push(String(url));
    const message = Buffer.from(JSON.stringify({
      type: "printwright-license-commitment", version: 1, algorithm: "sha256-jcs-v1", commitment,
    })).toString("base64");
    return {
      ok: true,
      text: async () => JSON.stringify({ message, consensus_timestamp: "1784900303.804467718" }),
    };
  };
}

async function anchoredBundle(widget, overrides = {}) {
  const certificate = {
    ...VECTOR_CERT,
    cert_id: `pw-${"a1b2c3d4".repeat(3)}`,
    buyer_hint: "0.0.9613501",
    payment_tx: "0.0.7162784@1784900288.288350505",
    terms_hash: TERMS_HASH,
  };
  const nonce = "ff".repeat(32);
  return {
    proof_version: 1,
    algorithm: "sha256-jcs-v1",
    certificate,
    blinding_nonce: nonce,
    commitment: await widget.computeCommitment(certificate, nonce, globalThis.crypto.subtle),
    terms: { version: "v1", kind: "personal", hash: TERMS_HASH, text: TERMS_TEXT },
    hedera: {
      network: "testnet", topic_id: "0.0.9585069", sequence_number: 57, mirror_url: MIRROR_URL,
    },
    ...overrides,
  };
}

test("widget reproduces the cross-language commitment vector", async () => {
  const widget = loadWidget(async () => { throw new Error("no fetch expected"); });
  const commitment = await widget.computeCommitment(VECTOR_CERT, VECTOR_NONCE, globalThis.crypto.subtle);
  assert.equal(commitment, VECTOR_COMMITMENT);
});

test("widget canonicalization sorts keys like RFC 8785", () => {
  const widget = loadWidget(async () => {});
  assert.equal(widget.canonicalize({ b: 2, a: "x", v: 1 }), '{"a":"x","b":2,"v":1}');
});

test("widget verifies a bundle against the on-chain commitment", async () => {
  const requested = [];
  const widget = loadWidget(async () => {});
  const bundle = await anchoredBundle(widget);

  const result = await widget.verifyBundle(bundle, { fetchImpl: mirrorReturning(bundle.commitment, requested) });

  assert.equal(result.verified, true);
  assert.equal(result.checks.hedera_anchoring, "verified");
  assert.equal(result.checks.terms_integrity, "verified");
  assert.equal(result.checks.issuer_assertions, "not_independently_proven");
  assert.equal(result.consensus_timestamp, "1784900303.804467718");
});

test("widget ignores a mirror URL supplied by the bundle", async () => {
  const requested = [];
  const widget = loadWidget(async () => {});
  const bundle = await anchoredBundle(widget, {
    hedera: {
      network: "testnet", topic_id: "0.0.9585069", sequence_number: 57,
      mirror_url: "https://mirror.attacker.example/api/v1/topics/0.0.9585069/messages/57",
    },
  });
  bundle.commitment = await widget.computeCommitment(bundle.certificate, bundle.blinding_nonce, globalThis.crypto.subtle);

  const result = await widget.verifyBundle(bundle, { fetchImpl: mirrorReturning(bundle.commitment, requested) });

  assert.deepEqual(requested, [ MIRROR_URL ]);
  assert.equal(result.mirror_url, MIRROR_URL);
});

test("widget refuses a bundle anchored off the pinned topic", async () => {
  let called = false;
  const widget = loadWidget(async () => {});
  const bundle = await anchoredBundle(widget, {
    hedera: { network: "testnet", topic_id: "0.0.4242", sequence_number: 9 },
  });

  const result = await widget.verifyBundle(bundle, {
    expectedTopicId: "0.0.9585069",
    fetchImpl: async () => { called = true; },
  });

  assert.equal(result.checks.hedera_anchoring, "failed");
  assert.equal(result.verified, false);
  assert.equal(called, false);
});

test("widget fails a tampered certificate", async () => {
  const widget = loadWidget(async () => {});
  const bundle = await anchoredBundle(widget);
  bundle.certificate = { ...bundle.certificate, unit_serial: 999 };

  const result = await widget.verifyBundle(bundle, { fetchImpl: mirrorReturning(bundle.commitment) });

  assert.equal(result.checks.bundle_integrity, "failed");
  assert.equal(result.verified, false);
});

test("widget rejects the pre-commitment certificate shape", () => {
  const widget = loadWidget(async () => {});
  assert.ok(widget.validateCertificate({ ...VECTOR_CERT, designer: "0.0.5" }).length, "wallet-as-designer rejected");
  assert.ok(widget.validateCertificate({ ...VECTOR_CERT, cert_id: "pw-000001" }).length, "sequential id rejected");
});
