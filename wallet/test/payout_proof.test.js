import { test } from "node:test";
import assert from "node:assert/strict";
import { payoutMessageRequest } from "../payout_proof.js";

test("payout proof binds hedera_signMessage to the exact staged account and network", () => {
  assert.deepEqual(payoutMessageRequest({
    network: "testnet",
    connectedAccountId: "0.0.7007",
    expectedAccountId: "0.0.7007",
    message: "single-use challenge",
  }), {
    signerAccountId: "hedera:testnet:0.0.7007",
    message: "single-use challenge",
  });
});

test("payout proof refuses a different connected wallet before signing", () => {
  assert.throws(() => payoutMessageRequest({
    network: "testnet",
    connectedAccountId: "0.0.8008",
    expectedAccountId: "0.0.7007",
    message: "single-use challenge",
  }), /Connect the staged wallet 0\.0\.7007; 0\.0\.8008 is connected/);
});
