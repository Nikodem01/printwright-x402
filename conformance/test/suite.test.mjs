import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { lintPaymentRequired, runConformance } from "../suite.mjs";

let server;
let baseUrl;

before(async () => {
  server = http.createServer(async (request, response) => {
    const url = new URL(request.url, `http://${request.headers.host}`);
    response.setHeader("content-type", "application/json");
    if (url.pathname === "/api/v1/models") {
      return response.end(JSON.stringify({ count: 1, models: [ {
        id: 7, title: "Conformance clip", slug: "conformance-clip",
        license_offers: [ { kind: "personal", price_cents: 25 } ],
      } ] }));
    }
    if (url.pathname === "/api/v1/models/7/download") {
      assert.equal(request.headers["x-sandbox"], "true");
      if (!request.headers["payment-signature"]) {
        const challenge = paymentRequired(`${baseUrl}${request.url}`);
        response.statusCode = 402;
        response.setHeader("payment-required", Buffer.from(JSON.stringify(challenge)).toString("base64"));
        response.setHeader("x-printwright-sandbox", "true");
        return response.end(JSON.stringify(challenge));
      }
      const payment = JSON.parse(Buffer.from(request.headers["payment-signature"], "base64").toString("utf8"));
      assert.equal(payment.accepted.network, "hedera:sandbox");
      const settlement = Buffer.from(JSON.stringify({ success: true, sandbox: true })).toString("base64");
      response.setHeader("payment-response", settlement);
      response.setHeader("x-payment-response", settlement);
      response.setHeader("x-printwright-sandbox", "true");
      return response.end(JSON.stringify({
        sandbox: true, warning: "SIMULATION ONLY — NO HEDERA FUNDS MOVE",
        files: [ { kind: "sandbox_receipt", sandbox: true, url: `${baseUrl}/api/v1/sandbox/files/sandbox-pw-000007` } ],
        license: { cert_id: "sandbox-pw-000007", serial: 1, kind: "personal" },
        certificate: { cert_id: "sandbox-pw-000007", sandbox: true },
        verify_url: `${baseUrl}/verify/sandbox-pw-000007`, transaction_id: "sandbox:tx",
        hashscan_url: null, sandbox_url: `${baseUrl}/api/v1/sandbox/transactions/sandbox:tx`,
      }));
    }
    if (url.pathname === "/api/v1/sandbox/files/sandbox-pw-000007") {
      response.setHeader("content-type", "text/plain");
      return response.end("PRINTWRIGHT SANDBOX RECEIPT — NOT A LICENSE — NO FUNDS MOVED");
    }
    if (url.pathname === "/api/v1/certificates/sandbox-pw-000007") {
      const certificate = { cert_id: "sandbox-pw-000007", sandbox: true };
      return response.end(JSON.stringify({
        status: "sandbox", certificate,
        hcs: { sandbox: true, mirror_url: `${baseUrl}/api/v1/sandbox/topics/printwright-sandbox/messages/7` },
      }));
    }
    if (url.pathname === "/api/v1/sandbox/topics/printwright-sandbox/messages/7") {
      return response.end(JSON.stringify({
        sandbox: true,
        message: Buffer.from(JSON.stringify({ cert_id: "sandbox-pw-000007", sandbox: true })).toString("base64"),
      }));
    }
    response.statusCode = 404;
    response.end(JSON.stringify({ error: "not_found" }));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

after(() => server.close());

test("full public conformance runner validates the sandbox contract", async () => {
  const report = await runConformance({ baseUrl });
  assert.equal(report.conformant, true);
  assert.equal(report.cert_id, "sandbox-pw-000007");
  assert.equal(report.checks.length, 7);
});

test("PaymentRequired linter rejects a body/header mismatch and unsafe amount", () => {
  const challenge = paymentRequired("https://seller.example/resource");
  challenge.accepts[0].amount = "-1";
  const other = paymentRequired("https://seller.example/resource");
  const errors = lintPaymentRequired({
    resourceUrl: "https://seller.example/resource",
    body: challenge,
    encodedHeader: Buffer.from(JSON.stringify(other)).toString("base64"),
  });
  assert(errors.some((error) => /positive decimal string/.test(error)));
  assert(errors.some((error) => /header and body differ/.test(error)));
});

function paymentRequired(resourceUrl) {
  return {
    x402Version: 2, sandbox: true, warning: "SIMULATION ONLY — NO HEDERA FUNDS MOVE",
    resource: { url: resourceUrl, description: "sandbox fixture", mimeType: "application/json" },
    accepts: [ {
      scheme: "exact", network: "hedera:sandbox", amount: "25", asset: "sandbox:credit",
      payTo: "sandbox:designer", maxTimeoutSeconds: 180,
      extra: { feePayer: "sandbox:facilitator", sandbox: true },
    } ],
  };
}
