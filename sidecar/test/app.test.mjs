import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { createApp } from "../app.mjs";

const TOKEN = "test-token";
const calls = [];
const fakeHedera = {
  network: "testnet",
  treasuryConfigured: true,
  createTopic: async (memo) => {
    calls.push(["createTopic", memo]);
    return { topicId: "0.0.111", transactionId: "0.0.1@1.2" };
  },
  createHeartbeatTopic: async () => {
    calls.push(["createHeartbeatTopic"]);
    return { topicId: "0.0.222", transactionId: "0.0.1@2.2" };
  },
  submitMessage: async (topicId, message) => {
    calls.push(["submitMessage", topicId, message]);
    return { topicId, sequenceNumber: 7, transactionId: "0.0.1@3.4" };
  },
  payout: async ({ tokenId, transfers, memo }) => {
    calls.push(["payout", tokenId, transfers, memo]);
    return { transactionId: "0.0.1@5.6" };
  },
  createLicenseCollection: async (args) => {
    calls.push(["createLicenseCollection", args]);
    return { tokenId: "0.0.777", transactionId: "0.0.1@7.7" };
  },
  mintAndAirdrop: async (args) => {
    calls.push(["mintAndAirdrop", args]);
    return { serial: 1, mintTransactionId: "0.0.1@8.8", airdropTransactionId: "0.0.1@9.9", pending: true };
  },
};

let server;
let base;
let configuredTopic = "0.0.111";
let configuredHeartbeatTopic = "0.0.222";

before(async () => {
  server = createApp({
    hedera: fakeHedera,
    token: TOKEN,
    topicId: () => configuredTopic,
    heartbeatTopicId: () => configuredHeartbeatTopic,
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});
after(() => server.close());

const post = (path, body, headers = { authorization: `Bearer ${TOKEN}` }) =>
  fetch(base + path, {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  });

test("healthz is open and reports network + topic", async () => {
  const res = await fetch(`${base}/healthz`);
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { ok: true, network: "testnet", topicId: "0.0.111" });
});

test("rejects missing bearer token", async () => {
  const res = await post("/submit-cert", { cert: { v: 1 } }, {});
  assert.equal(res.status, 401);
});

test("rejects wrong bearer token", async () => {
  const res = await post("/create-topic", {}, { authorization: "Bearer wrong" });
  assert.equal(res.status, 401);
});

test("create-topic uses the default memo", async () => {
  const res = await post("/create-topic", {});
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { topicId: "0.0.111", transactionId: "0.0.1@1.2" });
  assert.deepEqual(calls.at(-1), ["createTopic", "printwright license certificates v1"]);
});

test("creates a dedicated heartbeat topic with fixed policy", async () => {
  const res = await post("/create-heartbeat-topic", {});
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { topicId: "0.0.222", transactionId: "0.0.1@2.2" });
  assert.deepEqual(calls.at(-1), ["createHeartbeatTopic"]);
});

test("submit-heartbeat accepts only the bounded pwh-1 schema", async () => {
  const heartbeat = {
    schema: "pwh-1",
    service: "printwright",
    status: "alive",
    network: "hedera:testnet",
    observed_at: "2026-07-19T12:00:00Z",
  };
  const res = await post("/submit-heartbeat", { heartbeat });
  assert.equal(res.status, 200);
  assert.deepEqual(calls.at(-1), ["submitMessage", "0.0.222", JSON.stringify(heartbeat)]);

  for (const invalid of [
    {},
    { ...heartbeat, schema: "pwc-1" },
    { ...heartbeat, service: "other" },
    { ...heartbeat, status: "healthy" },
    { ...heartbeat, network: "hedera:mainnet" },
    { ...heartbeat, observed_at: "today" },
    { ...heartbeat, extra: "not part of pwh-1" },
  ]) {
    const rejected = await post("/submit-heartbeat", { heartbeat: invalid });
    assert.equal(rejected.status, 400, JSON.stringify(invalid));
    assert.deepEqual(await rejected.json(), { error: "invalid_heartbeat" });
  }
});

test("submit-heartbeat refuses without its dedicated topic", async () => {
  configuredHeartbeatTopic = undefined;
  const res = await post("/submit-heartbeat", {
    heartbeat: {
      schema: "pwh-1", service: "printwright", status: "alive",
      network: "hedera:testnet", observed_at: "2026-07-19T12:00:00Z",
    },
  });
  assert.equal(res.status, 400);
  assert.deepEqual(await res.json(), { error: "no_heartbeat_topic_configured" });
  configuredHeartbeatTopic = "0.0.222";
});

test("submit-cert serializes compactly and returns sequence number", async () => {
  const cert = { v: 1, cert_id: "pw-000001", unit_serial: 17 };
  const res = await post("/submit-cert", { cert });
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.sequenceNumber, 7);
  assert.equal(calls.at(-1)[2], JSON.stringify(cert)); // no whitespace
});

test("submit-version accepts only a compact pwv-1 update event", async () => {
  const version = { schema: "pwv-1", model_id: 48, version: 2, file_hash: `sha256:${"a".repeat(64)}` };
  const res = await post("/submit-version", { version });
  assert.equal(res.status, 200);
  assert.equal(calls.at(-1)[2], JSON.stringify(version));

  const invalid = await post("/submit-version", { version: { schema: "pwc-1" } });
  assert.equal(invalid.status, 400);
  assert.deepEqual(await invalid.json(), { error: "invalid_version_event" });
});

test("submit-version enforces the single-message limit", async () => {
  const res = await post("/submit-version", { version: { schema: "pwv-1", pad: "x".repeat(1100) } });
  assert.equal(res.status, 422);
  assert.equal((await res.json()).error, "version_event_too_large");
});

test("submit-cert without cert is a 400", async () => {
  const res = await post("/submit-cert", {});
  assert.equal(res.status, 400);
  assert.deepEqual(await res.json(), { error: "missing_cert" });
});

test("submit-cert over 1024 bytes is a 422", async () => {
  const res = await post("/submit-cert", { cert: { pad: "x".repeat(1100) } });
  assert.equal(res.status, 422);
  assert.equal((await res.json()).error, "cert_too_large");
});

test("submit-cert with no topic configured is a 400", async () => {
  configuredTopic = undefined;
  const res = await post("/submit-cert", { cert: { v: 1 } });
  assert.equal(res.status, 400);
  assert.deepEqual(await res.json(), { error: "no_topic_configured" });
  configuredTopic = "0.0.111";
});

test("hedera failure surfaces as 502, not a crash", async () => {
  const failing = { ...fakeHedera, submitMessage: async () => { throw new Error("boom"); } };
  const captured = [];
  const s = createApp({
    hedera: failing, token: TOKEN, topicId: () => "0.0.111",
    captureException: (error, context) => captured.push({ error, context }),
  });
  await new Promise((resolve) => s.listen(0, "127.0.0.1", resolve));
  const res = await fetch(`http://127.0.0.1:${s.address().port}/submit-cert`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${TOKEN}` },
    body: JSON.stringify({ cert: { v: 1 } }),
  });
  assert.equal(res.status, 502);
  assert.deepEqual(await res.json(), { error: "hedera_error" });
  assert.equal(captured.length, 1);
  assert.equal(captured[0].error.message, "boom");
  assert.equal(captured[0].context.tags.boundary, "request");
  s.close();
});

test("malformed JSON body is a 400", async () => {
  const res = await fetch(`${base}/submit-cert`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${TOKEN}` },
    body: "{not json",
  });
  assert.equal(res.status, 400);
  assert.deepEqual(await res.json(), { error: "invalid_json" });
});

test("unknown routes are 404", async () => {
  const res = await post("/delete-topic", {});
  assert.equal(res.status, 404);
});

test("payout requires auth", async () => {
  const res = await post("/payout", { tokenId: "0.0.1", transfers: [] }, {});
  assert.equal(res.status, 401);
});

test("payout validates token id, transfers, and amounts", async () => {
  for (const body of [
    { tokenId: "nope", transfers: [{ accountId: "0.0.5", amount: "1" }] },
    { tokenId: "0.0.1", transfers: [] },
    { tokenId: "0.0.1", transfers: [{ accountId: "eve", amount: "1" }] },
    { tokenId: "0.0.1", transfers: [{ accountId: "0.0.5", amount: "-3" }] },
    { tokenId: "0.0.1", transfers: [{ accountId: "0.0.5", amount: "0" }] },
    { tokenId: "0.0.1", transfers: [{ accountId: "0.0.5", amount: 5 }] },
  ]) {
    const res = await post("/payout", body);
    assert.equal(res.status, 400, JSON.stringify(body));
  }
});

test("payout passes transfers through and returns the tx id", async () => {
  const transfers = [
    { accountId: "0.0.9604186", amount: "225000" },
    { accountId: "0.0.9604185", amount: "90000" },
  ];
  const res = await post("/payout", { tokenId: "0.0.429274", transfers, memo: "test payout" });
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { transactionId: "0.0.1@5.6" });
  assert.deepEqual(calls.at(-1), ["payout", "0.0.429274", transfers, "test payout"]);
});

test("payout without treasury key is 503", async () => {
  const bare = createApp({
    hedera: { ...fakeHedera, treasuryConfigured: false },
    token: TOKEN,
    topicId: () => "0.0.111",
  });
  await new Promise((resolve) => bare.listen(0, "127.0.0.1", resolve));
  const port = bare.address().port;
  const res = await fetch(`http://127.0.0.1:${port}/payout`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${TOKEN}` },
    body: JSON.stringify({ tokenId: "0.0.1", transfers: [{ accountId: "0.0.5", amount: "1" }] }),
  });
  assert.equal(res.status, 503);
  assert.equal((await res.json()).error, "treasury_not_configured");
  bare.close();
});

test("create-collection validates and passes through", async () => {
  for (const body of [
    { name: "", royaltyCollector: "0.0.5", royaltyPercent: 10 },
    { name: "X", royaltyCollector: "eve", royaltyPercent: 10 },
    { name: "X", royaltyCollector: "0.0.5", royaltyPercent: 99 },
  ]) {
    assert.equal((await post("/create-collection", body)).status, 400, JSON.stringify(body));
  }
  const res = await post("/create-collection", { name: "Printwright Licenses — A", royaltyCollector: "0.0.9604185", royaltyPercent: 10 });
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { tokenId: "0.0.777", transactionId: "0.0.1@7.7" });
  assert.equal(calls.at(-1)[0], "createLicenseCollection");
});

test("mint-airdrop validates and returns pending state", async () => {
  for (const body of [
    { tokenId: "bad", metadata: "pw-1", recipient: "0.0.5" },
    { tokenId: "0.0.777", metadata: "", recipient: "0.0.5" },
    { tokenId: "0.0.777", metadata: "x".repeat(101), recipient: "0.0.5" },
    { tokenId: "0.0.777", metadata: "pw-1", recipient: "nope" },
  ]) {
    assert.equal((await post("/mint-airdrop", body)).status, 400, JSON.stringify(body));
  }
  const res = await post("/mint-airdrop", { tokenId: "0.0.777", metadata: "pw-000001", recipient: "0.0.9067781" });
  assert.equal(res.status, 200);
  const out = await res.json();
  assert.equal(out.serial, 1);
  assert.equal(out.pending, true);
});
