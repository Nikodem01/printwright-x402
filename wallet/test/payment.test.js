import assert from "node:assert/strict";
import test from "node:test";
import { Transaction, TransferTransaction } from "@hiero-ledger/sdk";
import {
  buildPaymentTransaction,
  paymentSignatureHeaders,
  selectAcceptedPayment,
} from "../payment.js";

const accepted = {
  scheme: "exact",
  network: "hedera:testnet",
  amount: "10000000",
  asset: "0.0.0",
  payTo: "0.0.9584959",
  maxTimeoutSeconds: 180,
  extra: { feePayer: "0.0.7162784" },
};
const challenge = {
  x402Version: 2,
  resource: { url: "https://printwright.example/api/v1/models/1/download", mimeType: "application/json" },
  accepts: [accepted],
};

test("selects only the exact offer for the configured Hedera network", () => {
  const result = selectAcceptedPayment(challenge, "testnet");
  assert.equal(result.accepted, accepted);
  assert.equal(result.amount, 10000000n);
  assert.throws(() => selectAcceptedPayment(challenge, "mainnet"), /does not support Hedera mainnet/);
  assert.throws(() => selectAcceptedPayment(challenge, "previewnet"), /testnet or mainnet/);
});

test("builds a frozen transfer whose transaction payer is the facilitator", () => {
  const transaction = buildPaymentTransaction({
    accepted,
    amount: 10000000n,
    accountId: "0.0.9584901",
    network: "testnet",
  });
  assert.ok(transaction instanceof TransferTransaction);
  assert.equal(transaction.isFrozen(), true);
  assert.equal(transaction.transactionId.accountId.toString(), accepted.extra.feePayer);
  assert.ok(Transaction.fromBytes(transaction.toBytes()) instanceof TransferTransaction);
});

test("encodes the signed bytes and unmodified accepted offer in PAYMENT-SIGNATURE", () => {
  const bytes = new Uint8Array([1, 2, 3, 4]);
  const headers = paymentSignatureHeaders(challenge, accepted, bytes);
  const payload = JSON.parse(Buffer.from(headers["PAYMENT-SIGNATURE"], "base64").toString("utf8"));
  assert.deepEqual(payload.accepted, accepted);
  assert.deepEqual(payload.resource, challenge.resource);
  assert.equal(payload.payload.transaction, "AQIDBA==");
  assert.equal(payload.x402Version, 2);
});

test("rejects tampered selections and non-positive amounts before wallet signing", () => {
  assert.throws(
    () => paymentSignatureHeaders(challenge, { ...accepted, amount: "1" }, new Uint8Array([1])),
    /not present/
  );
  assert.throws(
    () => selectAcceptedPayment({ ...challenge, accepts: [{ ...accepted, amount: "0" }] }, "testnet"),
    /positive integer/
  );
});
