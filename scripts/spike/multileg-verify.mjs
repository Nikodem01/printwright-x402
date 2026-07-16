// V1 kill-test (H-2): does the facilitator's /verify accept a TransferTransaction
// with more than one recipient leg? Shapes V7 (split settle) vs its payout-job fallback.
//
// Three variants, verify-only (nothing settles, no funds move):
//   A control    buyer -250000            payTo +250000                 -> expect valid
//   B split      buyer -250000            payTo +225000, extra +25000   -> ?
//   C tip-leg    buyer -275000            payTo +250000, extra +25000   -> ?
//
// Usage: HEDERA_ACCOUNT_ID=0.0.x HEDERA_PRIVATE_KEY=0x... node scripts/spike/multileg-verify.mjs
import "dotenv/config";
import {
  AccountId,
  Client,
  Hbar,
  PrivateKey,
  TokenId,
  TransactionId,
  TransferTransaction,
} from "@hiero-ledger/sdk";
import { wireLog } from "./wirelog.mjs";

const FACILITATOR = (process.env.X402_FACILITATOR_URL || "https://api.testnet.blocky402.com").replace(/\/$/, "");
const BUYER = process.env.HEDERA_ACCOUNT_ID;
const KEY = process.env.HEDERA_PRIVATE_KEY;
const PAY_TO = process.env.X402_PAY_TO || "0.0.9584959";
const EXTRA_RECIPIENT = "0.0.2"; // any existing account — verify never executes the tx
const USDC = "0.0.429274";

if (!BUYER || !KEY) throw new Error("HEDERA_ACCOUNT_ID and HEDERA_PRIVATE_KEY are required");

const { kinds } = await (await fetch(`${FACILITATOR}/supported`)).json();
const FEE_PAYER = kinds.find((k) => k.network === "hedera:testnet")?.extra?.feePayer;
if (!FEE_PAYER) throw new Error("facilitator does not list a hedera:testnet feePayer");

const requirements = {
  scheme: "exact",
  network: "hedera:testnet",
  amount: "250000",
  asset: USDC,
  payTo: PAY_TO,
  maxTimeoutSeconds: 180,
  extra: { feePayer: FEE_PAYER },
};

const variants = [
  { name: "A control single-leg", legs: [[BUYER, -250000n], [PAY_TO, 250000n]] },
  { name: "B split 90/10", legs: [[BUYER, -250000n], [PAY_TO, 225000n], [EXTRA_RECIPIENT, 25000n]] },
  { name: "C full amount + extra leg", legs: [[BUYER, -275000n], [PAY_TO, 250000n], [EXTRA_RECIPIENT, 25000n]] },
];

const buyerKey = PrivateKey.fromStringECDSA(KEY);
const client = Client.forTestnet();
const results = [];

for (const variant of variants) {
  const tx = new TransferTransaction();
  for (const [account, amount] of variant.legs) {
    tx.addTokenTransfer(TokenId.fromString(USDC), AccountId.fromString(account), Number(amount));
  }
  tx.setTransactionId(TransactionId.generate(AccountId.fromString(FEE_PAYER)));
  tx.freezeWith(client);
  const signed = await tx.sign(buyerKey);
  const transaction = Buffer.from(signed.toBytes()).toString("base64");

  const body = {
    x402Version: 2,
    paymentPayload: { x402Version: 2, payload: { transaction }, accepted: requirements },
    paymentRequirements: requirements,
  };
  const res = await fetch(`${FACILITATOR}/verify`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  const verdict = await res.json();
  wireLog("multileg.jsonl", {
    note: `${variant.name} -> ${res.status} ${JSON.stringify(verdict)}`,
    variant: variant.name,
    legs: variant.legs.map(([a, n]) => `${a}:${n}`),
    requestBody: { ...body, paymentPayload: { ...body.paymentPayload, payload: { transaction } } },
    status: res.status,
    responseBody: verdict,
  });
  results.push({ variant: variant.name, status: res.status, ...verdict });
}
client.close();

console.log("\n=== V1 multi-leg /verify kill-test ===");
for (const r of results) {
  console.log(`${r.variant.padEnd(28)} isValid=${r.isValid}${r.invalidReason ? `  reason=${r.invalidReason}` : ""}`);
}
const go = results.filter((r) => r.variant !== variants[0].name).some((r) => r.isValid);
console.log(`\nverdict: ${go ? "GO — facilitator accepts a multi-leg settle" : "NO-GO — single-recipient only; V7 falls back to the payout job"}`);
