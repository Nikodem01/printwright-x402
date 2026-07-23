import { test } from "node:test";
import assert from "node:assert/strict";
import { PrivateKey } from "@hiero-ledger/sdk";
import { proto } from "@hiero-ledger/proto";
import { payoutProofPayload, payoutProofSignature } from "../hedera.mjs";

test("payout proof decodes ED25519 and ECDSA WalletConnect signatures over Hedera's prefix", () => {
  const message = [
    "Printwright payout destination verification",
    "Network: testnet",
    "Designer: 7",
    "Account: 0.0.7007",
    "Nonce: abc123",
  ].join("\n");
  const payload = payoutProofPayload(message);

  for (const [key, field] of [
    [PrivateKey.generateED25519(), "ed25519"],
    [PrivateKey.generateECDSA(), "ECDSASecp256k1"],
  ]) {
    const signatureMap = Buffer.from(proto.SignatureMap.encode({
      sigPair: [ { [field]: key.sign(payload) } ],
    }).finish()).toString("base64");

    assert.equal(key.publicKey.verify(payload, payoutProofSignature(signatureMap)), true);
    assert.equal(key.publicKey.verify(
      payoutProofPayload(`${message}x`), payoutProofSignature(signatureMap)
    ), false);
  }
});

test("payout proof refuses ambiguous or unsupported SignatureMaps", () => {
  const twoSignatures = Buffer.from(proto.SignatureMap.encode({
    sigPair: [ { ed25519: Buffer.alloc(64) }, { ed25519: Buffer.alloc(64) } ],
  }).finish()).toString("base64");
  const unsupported = Buffer.from(proto.SignatureMap.encode({
    sigPair: [ { RSA_3072: Buffer.alloc(64) } ],
  }).finish()).toString("base64");

  assert.equal(payoutProofSignature(twoSignatures), null);
  assert.equal(payoutProofSignature(unsupported), null);
});
