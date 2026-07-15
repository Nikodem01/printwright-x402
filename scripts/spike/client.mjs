// Reference x402 buyer client, driven leg-by-leg (instead of a fetch wrapper)
// so every wire byte can be logged: GET → 402 → build+sign payment → retry →
// 200 + PAYMENT-RESPONSE. Captures to wire-log/client.jsonl.
import "dotenv/config";
import { x402Client, x402HTTPClient } from "@x402/core/client";
import { createClientHederaSigner, PrivateKey } from "@x402/hedera";
import { ExactHederaScheme } from "@x402/hedera/exact/client";
import { wireLog } from "./wirelog.mjs";

const RESOURCE_URL = process.env.RESOURCE_URL || "http://127.0.0.1:4402/premium";
const ACCOUNT_ID = process.env.HEDERA_ACCOUNT_ID;
const PRIVATE_KEY = process.env.HEDERA_PRIVATE_KEY;

const signer = createClientHederaSigner(ACCOUNT_ID, PrivateKey.fromStringECDSA(PRIVATE_KEY), {
  network: "hedera:testnet",
});
const client = new x402Client().register("hedera:*", new ExactHederaScheme(signer));
const httpClient = new x402HTTPClient(client);

async function loggedFetch(note, url, options = {}) {
  const response = await fetch(url, options);
  const bodyText = await response.text();
  wireLog("client.jsonl", {
    note,
    url,
    method: options.method || "GET",
    requestHeaders: options.headers || {},
    status: response.status,
    responseHeaders: Object.fromEntries(response.headers),
    responseBody: bodyText,
  });
  return { response, bodyText };
}

// Leg 1 — unauthenticated request, expect 402
const leg1 = await loggedFetch("leg1: bare GET, expecting 402", RESOURCE_URL, {
  headers: { accept: "application/json" },
});
if (leg1.response.status !== 402) {
  throw new Error(`expected 402, got ${leg1.response.status}: ${leg1.bodyText}`);
}

const paymentRequired = httpClient.getPaymentRequiredResponse(
  (name) => leg1.response.headers.get(name),
  JSON.parse(leg1.bodyText)
);
console.log("\nPaymentRequired accepts:", JSON.stringify(paymentRequired.accepts, null, 2));

// Leg 2 — build + partially sign the TransferTransaction, encode header(s)
const paymentPayload = await httpClient.createPaymentPayload(paymentRequired);
const paymentHeaders = httpClient.encodePaymentSignatureHeader(paymentPayload);
wireLog("client.jsonl", {
  note: "leg2: payment payload built",
  paymentPayload,
  headerNames: Object.keys(paymentHeaders),
});
console.log("\nPayment header names emitted:", Object.keys(paymentHeaders).join(", "));

// Leg 3 — retry with payment attached, expect 200 + PAYMENT-RESPONSE header
const leg3 = await loggedFetch("leg3: paid GET, expecting 200", RESOURCE_URL, {
  headers: { accept: "application/json", ...paymentHeaders },
});
if (leg3.response.status !== 200) {
  throw new Error(`expected 200, got ${leg3.response.status}: ${leg3.bodyText}`);
}

const settle = httpClient.getPaymentSettleResponse((name) => leg3.response.headers.get(name));
wireLog("client.jsonl", { note: "settle response decoded from PAYMENT-RESPONSE header", settle });

const txId = settle.transaction;
console.log("\n=== SETTLED ===");
console.log("payer:      ", settle.payer);
console.log("network:    ", settle.network);
console.log("transaction:", txId);
console.log(`hashscan:    https://hashscan.io/testnet/transaction/${txId}`);
