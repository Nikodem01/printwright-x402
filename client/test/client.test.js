import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { PrivateKey } from "@hiero-ledger/sdk";
import { PrintwrightClient, PrintwrightError } from "../index.js";

let server;
let baseUrl;
let paidRequests = 0;

const certificate = {
  cert_id: "pw-000007",
  model_hash: "sha256:abc",
  serial: 1,
};

before(async () => {
  server = http.createServer(async (request, response) => {
    const url = new URL(request.url, `http://${request.headers.host}`);
    response.setHeader("content-type", "application/json");

    if (url.pathname === "/api/v1/models" && url.searchParams.get("q") === "gear") {
      return response.end(JSON.stringify({ count: 1, models: [ { id: 7, title: "Gear" } ] }));
    }
    if (url.pathname === "/api/v1/models/7") {
      return response.end(JSON.stringify({ id: 7, title: "Gear", license_offers: [] }));
    }
    if (url.pathname === "/api/v1/models/7/download") {
      if (request.headers["payment-signature"]) {
        paidRequests += 1;
        return response.end(JSON.stringify({
          files: [], license: { cert_id: "pw-000007", serial: 1, kind: "personal" },
          hashscan_url: "https://hashscan.io/testnet/transaction/example",
        }));
      }
      response.statusCode = 402;
      const paymentRequired = {
        x402Version: 2,
        resource: {
          url: `${baseUrl}/api/v1/models/7/download?license=personal`,
          description: "personal print license for Gear",
          mimeType: "application/json",
        },
        accepts: [ {
          scheme: "exact", network: "hedera:testnet", payTo: "0.0.5678",
          maxTimeoutSeconds: 180, extra: { feePayer: "0.0.5678" },
          amount: "1", asset: "0.0.0",
        } ],
      };
      response.setHeader("payment-required", Buffer.from(JSON.stringify(paymentRequired)).toString("base64"));
      return response.end(JSON.stringify(paymentRequired));
    }
    if (url.pathname === "/api/v1/certificates/pw-000007") {
      return response.end(JSON.stringify({
        status: "anchored", certificate,
        hcs: { mirror_url: `${baseUrl}/mirror/messages/7` },
      }));
    }
    if (url.pathname === "/api/v1/certificates/pw-000008") {
      return response.end(JSON.stringify({
        status: "anchored", certificate,
        hcs: { mirror_url: `${baseUrl}/mirror/messages/8` },
      }));
    }
    if (url.pathname === "/mirror/messages/7") {
      return response.end(JSON.stringify({
        message: Buffer.from(JSON.stringify({ serial: 1, cert_id: "pw-000007", model_hash: "sha256:abc" }))
          .toString("base64"),
        consensus_timestamp: "123.456",
      }));
    }

    response.statusCode = 404;
    response.end(JSON.stringify({ error: "not found" }));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

after(() => server.close());

test("searches and gets catalog models without payment credentials", async () => {
  const client = new PrintwrightClient({ baseUrl });

  const search = await client.search({ query: "gear", maxPriceCents: 0, supports: false });
  assert.equal(search.count, 1);
  assert.equal(search.models[0].id, 7);
  assert.equal((await client.get(7)).title, "Gear");
});

test("quotes, signs offline, and retries the selected x402 requirement", async () => {
  const client = new PrintwrightClient({
    baseUrl,
    accountId: "0.0.1234",
    privateKey: PrivateKey.generateECDSA().toStringRaw(),
  });

  const quote = await client.quote({ modelId: 7, license: "personal", asset: "hbar" });
  assert.equal(quote.accepted.asset, "0.0.0");
  assert.throws(() => { quote.accepted.amount = "999"; }, /read only/);
  await assert.rejects(
    () => new PrintwrightClient({
      baseUrl, accountId: "0.0.1234", privateKey: PrivateKey.generateECDSA().toStringRaw(),
    }).buy({ quote }),
    /this client\.quote/
  );
  const receipt = await client.buy({ quote });

  assert.equal(receipt.license.cert_id, "pw-000007");
  assert.equal(paidRequests, 1);
});

test("verifies an anchored certificate independent of JSON key order", async () => {
  const proof = await new PrintwrightClient({ baseUrl }).verify("pw-000007");

  assert.equal(proof.match, true);
  assert.deepEqual(proof.onchain, { serial: 1, cert_id: "pw-000007", model_hash: "sha256:abc" });
  assert.equal(proof.consensus_timestamp, "123.456");
});

test("reports mirror indexing lag without turning an anchored certificate into an error", async () => {
  const proof = await new PrintwrightClient({ baseUrl }).verify("pw-000008");

  assert.equal(proof.status, "anchored");
  assert.equal(proof.match, null);
  assert.match(proof.note, /still indexing/);
});

test("rejects malformed ids, networks, and missing buyer credentials", async () => {
  assert.throws(() => new PrintwrightClient({ baseUrl, network: "previewnet" }), /testnet or mainnet/);
  await assert.rejects(() => new PrintwrightClient({ baseUrl }).get("7/../8"), /positive integer/);
  await assert.rejects(
    () => new PrintwrightClient({ baseUrl }).buy({ modelId: 7 }),
    (error) => error instanceof PrintwrightError && /accountId and privateKey/.test(error.message)
  );
});
