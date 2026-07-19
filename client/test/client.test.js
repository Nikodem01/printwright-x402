import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { PrivateKey } from "@hiero-ledger/sdk";
import { PrintwrightClient, PrintwrightError } from "../index.js";

let server;
let baseUrl;
let paidRequests = 0;
let paidBatchRequests = 0;
let lastBatchBodies = [];
let lastSearchParams;
let lastPrintReport;

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
      lastSearchParams = url.searchParams;
      return response.end(JSON.stringify({ count: 1, models: [ { id: 7, title: "Gear" } ] }));
    }
    if (url.pathname === "/api/v1/models/7") {
      return response.end(JSON.stringify({ id: 7, title: "Gear", license_offers: [] }));
    }
    if (url.pathname === "/api/v1/batches" && request.method === "POST") {
      const body = await requestBody(request);
      lastBatchBodies.push(body);
      if (request.headers["payment-signature"]) {
        paidBatchRequests += 1;
        return response.end(JSON.stringify({
          batch_id: 3, transaction_id: "0.0.7@1.2", hashscan_url: "https://hashscan.example/tx",
          sandbox: false,
          licenses: body.items.map((item, index) => ({
            model_id: item.model_id, kind: item.license, cert_id: `pw-00001${index}`,
            serial: index + 1, verify_url: `${baseUrl}/verify/pw-00001${index}`, files: [],
            print_feedback: {
              url: `${baseUrl}/api/v1/licenses/pw-00001${index}/print_reports`,
              receipt_token: `receipt-${index}`,
            },
          })),
        }));
      }
      response.statusCode = 402;
      const paymentRequired = {
        x402Version: 2,
        resource: { url: `${baseUrl}/api/v1/batches`, description: "batch", mimeType: "application/json" },
        accepts: [ {
          scheme: "exact", network: "hedera:testnet", payTo: "0.0.5678",
          maxTimeoutSeconds: 180, extra: { feePayer: "0.0.5678" },
          amount: "3", asset: "0.0.0",
        } ],
        batch: { license_count: body.items.length },
      };
      response.setHeader("payment-required", Buffer.from(JSON.stringify(paymentRequired)).toString("base64"));
      return response.end(JSON.stringify(paymentRequired));
    }
    if (url.pathname === "/api/v1/models/7/download") {
      if (request.headers["x-sandbox"] === "true") {
        if (request.headers["payment-signature"]) {
          const payload = JSON.parse(Buffer.from(request.headers["payment-signature"], "base64").toString("utf8"));
          assert.match(payload.payload.transaction, /^sandbox:/);
          return response.end(JSON.stringify({
            sandbox: true, warning: "SIMULATION ONLY", files: [],
            license: { cert_id: "sandbox-pw-000009", serial: 1, kind: "personal" },
            hashscan_url: null,
          }));
        }
        response.statusCode = 402;
        const sandboxRequired = {
          x402Version: 2, sandbox: true, warning: "SIMULATION ONLY",
          resource: { url: `${baseUrl}${url.pathname}?license=personal`, mimeType: "application/json" },
          accepts: [ {
            scheme: "exact", network: "hedera:sandbox", amount: "25",
            asset: "sandbox:credit", payTo: "sandbox:designer", maxTimeoutSeconds: 180,
            extra: { feePayer: "sandbox:facilitator", sandbox: true },
          } ],
        };
        response.setHeader("payment-required", Buffer.from(JSON.stringify(sandboxRequired)).toString("base64"));
        return response.end(JSON.stringify(sandboxRequired));
      }
      if (request.headers["payment-signature"]) {
        paidRequests += 1;
        return response.end(JSON.stringify({
          files: [], license: { cert_id: "pw-000007", serial: 1, kind: "personal" },
          print_feedback: {
            url: `${baseUrl}/api/v1/licenses/pw-000007/print_reports`, receipt_token: "receipt-7",
          },
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
    if (url.pathname === "/api/v1/licenses/pw-000007/can") {
      const qty = Number(url.searchParams.get("qty"));
      return response.end(JSON.stringify({
        cert_id: "pw-000007", use: url.searchParams.get("use"), qty,
        allowed: qty <= 1, reason_code: qty <= 1 ? "allowed" : "commercial_unit_limit",
      }));
    }
    if (url.pathname === "/api/v1/licenses/pw-000007/print_reports" && request.method === "POST") {
      lastPrintReport = await requestBody(request);
      response.statusCode = 201;
      return response.end(JSON.stringify({ cert_id: "pw-000007", successful_prints: 1 }));
    }
    if (url.pathname === "/api/v1/certificates/pw-000008") {
      return response.end(JSON.stringify({
        status: "anchored", certificate,
        hcs: { mirror_url: `${baseUrl}/mirror/messages/8` },
      }));
    }
    if (url.pathname === "/api/v1/certificates/sandbox-pw-000009") {
      const sandboxCertificate = { cert_id: "sandbox-pw-000009", sandbox: true };
      return response.end(JSON.stringify({
        status: "sandbox", certificate: sandboxCertificate,
        hcs: { sandbox: true, mirror_url: "/sandbox/messages/9" },
      }));
    }
    if (url.pathname === "/mirror/messages/7") {
      return response.end(JSON.stringify({
        message: Buffer.from(JSON.stringify({ serial: 1, cert_id: "pw-000007", model_hash: "sha256:abc" }))
          .toString("base64"),
        consensus_timestamp: "123.456",
      }));
    }
    if (url.pathname === "/sandbox/messages/9") {
      return response.end(JSON.stringify({
        sandbox: true,
        message: Buffer.from(JSON.stringify({ cert_id: "sandbox-pw-000009", sandbox: true })).toString("base64"),
        consensus_timestamp: "sandbox-local",
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

  const search = await client.search({
    query: "gear", maxPriceCents: 0, supports: false,
    category: "toys-and-games", collection: "under-an-hour",
  });
  assert.equal(search.count, 1);
  assert.equal(search.models[0].id, 7);
  assert.equal(lastSearchParams.get("category"), "toys-and-games");
  assert.equal(lastSearchParams.get("collection"), "under-an-hour");
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

test("completes a labeled sandbox purchase without an account or private key", async () => {
  const client = new PrintwrightClient({ baseUrl, sandbox: true });

  const quote = await client.quote({ modelId: 7 });
  assert.equal(quote.sandbox, true);
  assert.equal(quote.accepted.network, "hedera:sandbox");
  const receipt = await client.buy({ quote });

  assert.equal(receipt.sandbox, true);
  assert.match(receipt.license.cert_id, /^sandbox-pw-/);
  assert.equal(receipt.hashscan_url, null);

  const proof = await client.verify(receipt.license.cert_id);
  assert.equal(proof.status, "sandbox");
  assert.equal(proof.match, true);
  assert.equal(proof.onchain.sandbox, true);
});

test("posts an identical batch body across one aggregate x402 negotiation", async () => {
  const client = new PrintwrightClient({
    baseUrl,
    accountId: "0.0.1234",
    privateKey: PrivateKey.generateECDSA().toStringRaw(),
  });
  const items = Array.from({ length: 3 }, () => ({ modelId: 7, license: "commercial_unit" }));
  const webhook = {
    url: "https://buyer.example/certificates",
    secret: "buyer_webhook_secret_32_bytes_long",
  };

  const quote = await client.quoteBatch({ items, asset: "hbar", webhook });
  assert.equal(quote.paymentRequired.batch.license_count, 3);
  assert.equal(quote.accepted.amount, "3");
  assert.deepEqual(JSON.parse(quote.requestBody).webhook, webhook);
  const receipt = await client.buyBatch({ quote });

  assert.equal(receipt.licenses.length, 3);
  assert.equal(paidBatchRequests, 1);
  assert.deepEqual(lastBatchBodies.at(-2), lastBatchBodies.at(-1));
  await assert.rejects(
    () => new PrintwrightClient({ baseUrl }).buyBatch({ quote }),
    /this client\.quoteBatch/
  );
});

test("verifies an anchored certificate independent of JSON key order", async () => {
  const proof = await new PrintwrightClient({ baseUrl }).verify("pw-000007");

  assert.equal(proof.match, true);
  assert.deepEqual(proof.onchain, { serial: 1, cert_id: "pw-000007", model_hash: "sha256:abc" });
  assert.equal(proof.consensus_timestamp, "123.456");
});

test("checks a structured license decision without payment credentials", async () => {
  const client = new PrintwrightClient({ baseUrl });

  const one = await client.can({ certId: "pw-000007", use: "commercial_print" });
  const three = await client.can({ certId: "pw-000007", use: "commercial_print", qty: 3 });
  assert.equal(one.allowed, true);
  assert.equal(three.allowed, false);
  assert.equal(three.reason_code, "commercial_unit_limit");
  await assert.rejects(() => client.can({ certId: "pw-000007", use: "commercial_print", qty: 0 }),
    /positive integer/);
});

test("reports a successful print with the paid receipt capability", async () => {
  const client = new PrintwrightClient({ baseUrl });
  const result = await client.reportPrint({ certId: "pw-000007", receiptToken: "receipt-7" });

  assert.deepEqual(lastPrintReport, { receipt_token: "receipt-7" });
  assert.deepEqual(result, { cert_id: "pw-000007", successful_prints: 1 });
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
  await assert.rejects(() => new PrintwrightClient({ baseUrl }).quoteBatch({ items: [] }), /1 to 20/);
  await assert.rejects(
    () => new PrintwrightClient({ baseUrl }).quoteBatch({
      items: [ { modelId: 7 } ], webhook: { url: "http://127.0.0.1", secret: "short" },
    }),
    /HTTPS on port 443/
  );
});

async function requestBody(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}
