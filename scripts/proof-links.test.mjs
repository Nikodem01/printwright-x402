import assert from "node:assert/strict";
import test from "node:test";
import { proofLines } from "./proof-links.mjs";

const BASE = "http://localhost:3000";
const CERT_ID = "pw-049b9acd7b1f4a45652f3483";

// Exactly what Certificates::Bundle serves while CertMintJob is still retrying.
const MINTING = { status: "minting", hedera: { status: "minting" } };

const ANCHORED = {
  status: "anchored",
  commitment: "ae241c97ec0606db1062fec84a7b6d5fd5579f1f4df1a5d9724c195a48ec476f",
  hedera: {
    network: "testnet",
    topic_id: "0.0.9585069",
    sequence_number: 60,
    mirror_url: "https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9585069/messages/60",
    hashscan_url: "https://hashscan.io/testnet/topic/0.0.9585069",
  },
};

test("a still-minting certificate never prints undefined at a proof link", () => {
  const lines = proofLines(MINTING, { baseUrl: BASE, certId: CERT_ID });

  for (const line of lines) assert.doesNotMatch(line, /undefined/);
  assert.match(lines.join("\n"), /HCS topic:\s+pending/);
  assert.match(lines.join("\n"), /Mirror node:\s+pending/);
});

test("the pending state names a command that works unchanged once anchored", () => {
  const lines = proofLines(MINTING, { baseUrl: BASE, certId: CERT_ID });

  assert.match(
    lines.join("\n"),
    new RegExp(`node verifier/cli\\.js ${BASE}/api/v1/certificates/${CERT_ID}`)
  );
});

test("an anchored certificate still reports the real HashScan and mirror links", () => {
  const lines = proofLines(ANCHORED, { baseUrl: BASE, certId: CERT_ID }).join("\n");

  assert.match(lines, /HCS topic:\s+https:\/\/hashscan\.io\/testnet\/topic\/0\.0\.9585069/);
  assert.match(lines, /Mirror node:\s+https:\/\/testnet\.mirrornode\.hedera\.com\/api\/v1\/topics\/0\.0\.9585069\/messages\/60/);
  assert.match(lines, /Commitment:\s+ae241c97/);
  assert.doesNotMatch(lines, /undefined|pending/);
});

test("a sandbox anchor is labelled so it is never mistaken for a public topic", () => {
  const sandbox = {
    status: "sandbox",
    commitment: "abc",
    hedera: { sandbox: true, topic_id: "0.0.999", mirror_url: "/api/v1/sandbox/topics/0.0.999/messages/1" },
  };

  const lines = proofLines(sandbox, { baseUrl: BASE, certId: CERT_ID }).join("\n");

  assert.match(lines, /0\.0\.999 \(LOCAL SANDBOX ONLY\)/);
  assert.doesNotMatch(lines, /undefined/);
});
