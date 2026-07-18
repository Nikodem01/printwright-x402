// Regression tests for the buy_license refusal paths — this is a real-money
// tool, so every guardrail must keep refusing for the *stated* reason, not
// just "isError: true". Drives the real server.mjs over stdio like any MCP
// client would, against a throwaway stub marketplace (no dependency on the
// Rails app being up). No case here ever reaches purchase(): every one is
// refused before any payment would be attempted.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import http from "node:http";

const SERVER = fileURLToPath(new URL("../server.mjs", import.meta.url));

// Just enough of the /api/v1/models/:id shape for buy_license to read
// license_offers off of.
const MODELS = {
  10: { id: 10, license_offers: [ { kind: "commercial_unit", price_cents: 200 } ] }, // no "personal" offer
  20: { id: 20, license_offers: [ { kind: "personal", price_cents: 600 } ] },        // over the default 500c cap
  30: { id: 30, license_offers: [ { kind: "personal", price_cents: 1 } ] },          // cheap, but not free
};

let marketplace, BASE;

before(async () => {
  marketplace = http.createServer((req, res) => {
    const match = req.url.match(/^\/api\/v1\/models\/(\d+)$/);
    const model = match && MODELS[match[1]];
    if (model) {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify(model));
    } else {
      res.writeHead(404, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "not found" }));
    }
  });
  await new Promise((resolve) => marketplace.listen(0, "127.0.0.1", resolve));
  BASE = `http://127.0.0.1:${marketplace.address().port}`;
});

after(() => marketplace.close());

// No credentials by default: BUYER_* and the HEDERA_* fallbacks are all
// blanked out so each test controls exactly which are present.
const NO_CREDS = { BUYER_ACCOUNT_ID: "", BUYER_PRIVATE_KEY: "", HEDERA_ACCOUNT_ID: "", HEDERA_PRIVATE_KEY: "" };
const DUMMY_CREDS = { ...NO_CREDS, BUYER_ACCOUNT_ID: "0.0.1234", BUYER_PRIVATE_KEY: "0xdeadbeef" };

async function callBuyLicense(env, args) {
  const server = spawn(process.execPath, [ SERVER ], {
    env: { ...process.env, PRINTWRIGHT_URL: BASE, ...env },
    stdio: [ "pipe", "pipe", "inherit" ],
  });
  try {
    const send = (msg) => server.stdin.write(JSON.stringify(msg) + "\n");
    const messages = [];
    let buffer = "";
    server.stdout.on("data", (chunk) => {
      buffer += chunk;
      let idx;
      while ((idx = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, idx).trim();
        buffer = buffer.slice(idx + 1);
        if (line) messages.push(JSON.parse(line));
      }
    });

    send({ jsonrpc: "2.0", id: 1, method: "initialize", params: {
      protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "guardrail-test", version: "0" } } });
    await waitFor(() => messages.some((m) => m.id === 1));
    send({ jsonrpc: "2.0", method: "notifications/initialized" });
    send({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "buy_license", arguments: args } });
    await waitFor(() => messages.some((m) => m.id === 2));

    return messages.find((m) => m.id === 2).result;
  } finally {
    server.kill();
  }
}

function waitFor(ready, ms = 5000) {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    const tick = () => {
      if (ready()) return resolve();
      if (Date.now() - start > ms) return reject(new Error("timed out"));
      setTimeout(tick, 50);
    };
    tick();
  });
}

test("refuses without confirm: true", async () => {
  const result = await callBuyLicense(DUMMY_CREDS,
    { model_id: 10, license: "commercial_unit", confirm: false });
  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /confirm: true/);
});

test("refuses when BUYER_ACCOUNT_ID is missing", async () => {
  const result = await callBuyLicense({ ...NO_CREDS, BUYER_PRIVATE_KEY: "0xdeadbeef" },
    { model_id: 10, license: "commercial_unit", confirm: true });
  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /BUYER_ACCOUNT_ID \/ BUYER_PRIVATE_KEY not configured/);
});

test("refuses when BUYER_PRIVATE_KEY is missing", async () => {
  const result = await callBuyLicense({ ...NO_CREDS, BUYER_ACCOUNT_ID: "0.0.1234" },
    { model_id: 10, license: "commercial_unit", confirm: true });
  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /BUYER_ACCOUNT_ID \/ BUYER_PRIVATE_KEY not configured/);
});

test("refuses when the model has no offer of the requested license kind", async () => {
  // model 10 only has a commercial_unit offer; default license is "personal".
  const result = await callBuyLicense(DUMMY_CREDS, { model_id: 10, confirm: true });
  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /model 10 has no personal offer/);
});

test("refuses when the offer price exceeds MAX_SPEND_CENTS (default 500)", async () => {
  const result = await callBuyLicense(DUMMY_CREDS, { model_id: 20, license: "personal", confirm: true });
  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /offer is 600c, over the MAX_SPEND_CENTS=500 guardrail/);
});

test("MAX_SPEND_CENTS=0 boots and refuses every priced offer", async () => {
  const result = await callBuyLicense({ ...DUMMY_CREDS, MAX_SPEND_CENTS: "0" },
    { model_id: 30, license: "personal", confirm: true });
  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /offer is 1c, over the MAX_SPEND_CENTS=0 guardrail/);
});
