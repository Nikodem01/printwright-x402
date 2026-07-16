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
  submitMessage: async (topicId, message) => {
    calls.push(["submitMessage", topicId, message]);
    return { topicId, sequenceNumber: 7, transactionId: "0.0.1@3.4" };
  },
  payout: async ({ tokenId, transfers, memo }) => {
    calls.push(["payout", tokenId, transfers, memo]);
    return { transactionId: "0.0.1@5.6" };
  },
};

let server;
let base;
let configuredTopic = "0.0.111";

before(async () => {
  server = createApp({ hedera: fakeHedera, token: TOKEN, topicId: () => configuredTopic });
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

test("submit-cert serializes compactly and returns sequence number", async () => {
  const cert = { v: 1, cert_id: "pw-000001", unit_serial: 17 };
  const res = await post("/submit-cert", { cert });
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.sequenceNumber, 7);
  assert.equal(calls.at(-1)[2], JSON.stringify(cert)); // no whitespace
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
  const s = createApp({ hedera: failing, token: TOKEN, topicId: () => "0.0.111" });
  await new Promise((resolve) => s.listen(0, "127.0.0.1", resolve));
  const res = await fetch(`http://127.0.0.1:${s.address().port}/submit-cert`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${TOKEN}` },
    body: JSON.stringify({ cert: { v: 1 } }),
  });
  assert.equal(res.status, 502);
  assert.equal((await res.json()).error, "hedera_error");
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
