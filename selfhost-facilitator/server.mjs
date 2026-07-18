// Self-hosted x402 facilitator (Hedera exact scheme) — the fallback for the
// hosted Blocky402 endpoint. It is the Hedera slice of the x402-foundation
// reference facilitator (examples/typescript/facilitator/advanced/all_networks.ts),
// standalone on the published @x402/core + @x402/hedera packages. It speaks the
// exact /supported /verify /settle contract Printwright's FacilitatorClient uses,
// so switching to it is a single env var: X402_FACILITATOR_URL=http://host:4022.
//
// Run:  HEDERA_ACCOUNT_ID=0.0.x HEDERA_PRIVATE_KEY=<ecdsa> node server.mjs
// The account is the fee-payer: it sponsors network fees and submits the buyer's
// signed transfer. It must be a funded ECDSA account, and — per the scheme's
// fee-payer safety check — must never be the buyer or the payTo of a payment.
import { x402Facilitator } from "@x402/core/facilitator";
import {
  AccountId,
  PrivateKey,
  createHederaClient,
  createHederaSignAndSubmitTransaction,
  createHederaVerifyPayerSignature,
  createHederaPreflightTransfer,
  toFacilitatorHederaSigner,
} from "@x402/hedera";
import { ExactHederaScheme } from "@x402/hedera/exact/facilitator";
import express from "express";

const PORT = Number.parseInt(process.env.PORT || "4022", 10);
const NETWORK_NAME = process.env.HEDERA_NETWORK || "testnet";
const accountId = process.env.HEDERA_ACCOUNT_ID;
const privateKey = process.env.HEDERA_PRIVATE_KEY;

if (!accountId || !privateKey) {
  console.error("HEDERA_ACCOUNT_ID and HEDERA_PRIVATE_KEY (ECDSA fee-payer) are required");
  process.exit(1);
}
// Reject rather than default: silently settling on testnet while the operator
// believes they configured mainnet is the one mistake worth being loud about.
if (NETWORK_NAME !== "testnet" && NETWORK_NAME !== "mainnet") {
  console.error(`HEDERA_NETWORK must be "testnet" or "mainnet" (got "${NETWORK_NAME}")`);
  process.exit(1);
}
if (!Number.isInteger(PORT) || PORT < 1 || PORT > 65535) {
  console.error(`PORT must be a number 1-65535 (got "${process.env.PORT}")`);
  process.exit(1);
}
const NETWORK = `hedera:${NETWORK_NAME}`;
const MIRROR = NETWORK_NAME === "mainnet"
  ? "https://mainnet-public.mirrornode.hedera.com"
  : "https://testnet.mirrornode.hedera.com";

// Log the outcome only. The settle context carries the buyer's full signed
// transaction bytes; dumping it on every purchase makes logs enormous and puts
// payment payloads somewhere they don't need to be.
const facilitator = new x402Facilitator()
  .onAfterSettle(async (ctx) => {
    const r = ctx?.response?.result ?? ctx?.result;
    console.log(`settled: ${r?.transaction ?? "?"} payer=${r?.payer ?? "?"}`);
  })
  .onSettleFailure(async (ctx) => console.log("settle failure:", ctx?.error?.message ?? String(ctx?.error ?? "unknown")));

const key = PrivateKey.fromStringECDSA(privateKey);
const buildClient = (network) => createHederaClient(network).setOperator(AccountId.fromString(accountId), key);
const signer = toFacilitatorHederaSigner({
  getAddresses: () => [accountId],
  signAndSubmitTransaction: createHederaSignAndSubmitTransaction(buildClient, key),
  verifyPayerSignature: createHederaVerifyPayerSignature(),
  preflightTransfer: createHederaPreflightTransfer(),
});
facilitator.register(NETWORK, new ExactHederaScheme(signer));

const app = express();
app.use(express.json());

app.get("/supported", (_req, res) => res.json(facilitator.getSupported()));
app.get("/health", (_req, res) => res.json({ status: "ok" }));

app.post("/verify", async (req, res) => {
  const { paymentPayload, paymentRequirements } = req.body ?? {};
  if (!paymentPayload || !paymentRequirements) return res.status(400).json({ error: "missing paymentPayload or paymentRequirements" });
  try {
    res.json(await facilitator.verify(paymentPayload, paymentRequirements));
  } catch (e) {
    res.status(500).json({ error: e instanceof Error ? e.message : "unknown error" });
  }
});

app.post("/settle", async (req, res) => {
  const { paymentPayload, paymentRequirements } = req.body ?? {};
  if (!paymentPayload || !paymentRequirements) return res.status(400).json({ error: "missing paymentPayload or paymentRequirements" });
  try {
    res.json(await facilitator.settle(paymentPayload, paymentRequirements));
  } catch (e) {
    res.status(500).json({ error: e instanceof Error ? e.message : "unknown error" });
  }
});

// A 32-byte raw hex key parses as EITHER curve without error, so an ED25519 key
// (the Hedera portal's default) pasted here yields a valid-looking but wrong
// fee-payer identity — boot succeeds, /supported looks right, and every settle
// then fails with an opaque INVALID_SIGNATURE. Ask the mirror who this account
// actually is and fail here instead. Mirror unreachable: warn, don't block boot.
async function checkFeePayerKey() {
  let onChain;
  try {
    const res = await fetch(`${MIRROR}/api/v1/accounts/${accountId}`);
    if (!res.ok) throw new Error(`mirror returned ${res.status}`);
    onChain = (await res.json()).key;
  } catch (e) {
    console.warn(`warning: could not verify fee-payer key against the mirror (${e.message})`);
    return;
  }
  if (!onChain?.key) return;
  if (onChain.key.toLowerCase() !== key.publicKey.toStringRaw().toLowerCase()) {
    console.error(
      `HEDERA_PRIVATE_KEY does not match ${accountId} on ${NETWORK_NAME}.\n` +
      `  account's on-chain key: ${onChain._type} ${onChain.key}\n` +
      `  key you supplied derives: ECDSA_SECP256K1 ${key.publicKey.toStringRaw()}\n` +
      (onChain._type === "ED25519"
        ? "  That account is ED25519. This facilitator needs an ECDSA fee-payer —\n" +
          "  create one in the portal rather than reusing an ED25519 key."
        : "  Check you copied the private key for this account."),
    );
    process.exit(1);
  }
}
await checkFeePayerKey();

app.listen(PORT, () => {
  console.log(`self-host x402 facilitator on http://localhost:${PORT} (fee-payer ${accountId}, ${NETWORK})`);
  console.log(`kinds: ${JSON.stringify(facilitator.getSupported().kinds)}`);
});
