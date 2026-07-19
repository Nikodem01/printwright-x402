import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import http from "node:http";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { validateCertificate, VerificationError, verify } from "../index.js";

const execFileAsync = promisify(execFile);
const topicId = "0.0.9585069";
const certificate = Object.freeze({
  v: 1,
  cert_id: "pw-000058",
  model_id: 48,
  model_hash: `sha256:${"a".repeat(64)}`,
  designer: "0.0.9604186",
  license_type: "commercial_unit",
  unit_serial: 2,
  buyer_hint: "0.0.9067781",
  payment_tx: "0.0.7162784@1784449762.916833016",
  issued_at: "2026-07-19T08:29:37Z",
  terms_hash: `sha256:${"b".repeat(64)}`,
});

test("validates the frozen PWC-1 field contract", () => {
  assert.deepEqual(validateCertificate(certificate), []);
  const invalid = { ...certificate, surprise: true, model_hash: "abc", unit_serial: 0 };
  assert.deepEqual(validateCertificate(invalid), [
    "unknown fields: surprise",
    "model_hash must be sha256:<64 lowercase hex>",
    "unit_serial must be a positive integer",
  ]);
});

test("verifies an exact mirror-message URL and its location", async () => {
  const messageUrl = `https://mirror.example/api/v1/topics/${topicId}/messages/50`;
  const result = await verify(messageUrl, { fetch: fakeFetch(envelope()) });
  assert.equal(result.verified, true);
  assert.equal(result.standard, "PWC-1");
  assert.equal(result.certificate.cert_id, "pw-000058");
  assert.equal(result.sequence_number, 50);

  await assert.rejects(
    verify(messageUrl, { fetch: fakeFetch(envelope({ sequence_number: 51 })) }),
    (error) => error instanceof VerificationError && error.code === "location_mismatch"
  );
});

test("finds a cert id through same-origin mirror pagination", async () => {
  const requests = [];
  const fetch = async (url) => {
    requests.push(String(url));
    const pageTwo = String(url).includes("timestamp=lt:");
    return jsonResponse(pageTwo ? { messages: [ envelope() ], links: { next: null } } : {
      messages: [ envelope({ message: encode({ ...certificate, cert_id: "pw-000057" }) }) ],
      links: { next: `/api/v1/topics/${topicId}/messages?limit=100&order=desc&timestamp=lt:2.0` },
    });
  };
  const result = await verify("https://printwright.example/verify/pw-000058", {
    mirror: "https://mirror.example", topic: topicId, fetch,
  });
  assert.equal(result.certificate.cert_id, "pw-000058");
  assert.equal(requests.length, 2);
  assert(requests.every((url) => url.startsWith("https://mirror.example/")));
  assert(requests.every((url) => !url.includes("printwright.example")));
});

test("rejects malformed payloads and cross-origin pagination", async () => {
  await assert.rejects(
    verify(`https://mirror.example/api/v1/topics/${topicId}/messages/50`, {
      fetch: fakeFetch(envelope({ message: "not base64" })),
    }),
    (error) => error.code === "invalid_certificate"
  );
  await assert.rejects(
    verify("pw-000058", {
      mirror: "https://mirror.example", topic: topicId,
      fetch: fakeFetch({ messages: [], links: { next: "https://attacker.example/messages" } }),
    }),
    (error) => error.code === "invalid_mirror_response"
  );
  const repeated = `/api/v1/topics/${topicId}/messages?limit=100&order=desc`;
  await assert.rejects(
    verify("pw-000058", {
      mirror: "https://mirror.example", topic: topicId,
      fetch: fakeFetch({ messages: [], links: { next: repeated } }),
    }),
    (error) => error.code === "invalid_mirror_response" && /repeated/.test(error.message)
  );
});

test("CLI verifies by id using only a mirror server", async (t) => {
  const requests = [];
  const server = http.createServer((request, response) => {
    requests.push(request.url);
    response.setHeader("content-type", "application/json");
    response.end(JSON.stringify({ messages: [ envelope() ], links: { next: null } }));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(() => server.close());

  const cli = fileURLToPath(new URL("../cli.js", import.meta.url));
  const { stdout } = await execFileAsync(process.execPath, [
    cli, "pw-000058", "--topic", topicId,
    "--mirror", `http://127.0.0.1:${server.address().port}`, "--json",
  ]);
  const result = JSON.parse(stdout);
  assert.equal(result.verified, true);
  assert.equal(result.certificate.cert_id, "pw-000058");
  assert.deepEqual(requests, [ `/api/v1/topics/${topicId}/messages?limit=100&order=desc` ]);
});

function envelope(overrides = {}) {
  return {
    topic_id: topicId,
    sequence_number: 50,
    consensus_timestamp: "1784449779.736670002",
    message: encode(certificate),
    ...overrides,
  };
}

function encode(value) {
  return Buffer.from(JSON.stringify(value)).toString("base64");
}

function fakeFetch(body) {
  return async () => jsonResponse(body);
}

function jsonResponse(body) {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}
