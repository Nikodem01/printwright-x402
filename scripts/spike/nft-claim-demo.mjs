// V14 claim demo: a buyer with a PLAIN wallet (zero auto-association slots)
// buys a license for real; the license NFT airdrop goes PENDING — visible on
// the public mirror — until the buyer's wallet claims it. Run end to end:
//
//   HEDERA_ACCOUNT_ID=0.0.x HEDERA_PRIVATE_KEY=0x... node scripts/spike/nft-claim-demo.mjs
//
// (operator creds fund the throwaway buyer; the buyer's own key signs the
// USDC association, the x402 payment, and the claim.)
import "dotenv/config";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import {
  AccountCreateTransaction,
  AccountId,
  Client,
  Hbar,
  NftId,
  PendingAirdropId,
  PrivateKey,
  TokenAssociateTransaction,
  TokenClaimAirdropTransaction,
  TokenId,
  TransferTransaction,
} from "@hiero-ledger/sdk";

const APP = (process.env.PRINTWRIGHT_URL || "http://localhost:3000").replace(/\/$/, "");
const MIRROR = "https://testnet.mirrornode.hedera.com";
const USDC = TokenId.fromString("0.0.429274");
const OPERATOR = AccountId.fromString(process.env.HEDERA_ACCOUNT_ID);
const client = Client.forTestnet().setOperator(OPERATOR, PrivateKey.fromStringECDSA(process.env.HEDERA_PRIVATE_KEY));

// ---- 1. a plain-wallet buyer: ZERO auto-association slots -------------------
const buyerKey = PrivateKey.generateECDSA();
const created = await new AccountCreateTransaction()
  .setECDSAKeyWithAlias(buyerKey).setInitialBalance(new Hbar(10))
  .setMaxAutomaticTokenAssociations(0).execute(client);
const buyer = (await created.getReceipt(client)).accountId;
console.log(`buyer (0 slots): ${buyer}  key=${buyerKey.toStringRaw()}`);

await (await (await new TokenAssociateTransaction()
  .setAccountId(buyer).setTokenIds([USDC]).freezeWith(client)).sign(buyerKey)).execute(client).then((r) => r.getReceipt(client));
await new TransferTransaction()
  .addTokenTransfer(USDC, OPERATOR, -1000000).addTokenTransfer(USDC, buyer, 1000000)
  .execute(client).then((r) => r.getReceipt(client));
console.log("buyer associated with USDC and funded ($1)");

// ---- 2. the buyer purchases a license for real ------------------------------
const out = await runBuy(buyer.toString(), buyerKey.toStringRaw());
const certId = out.match(/License:\s+(\S+)/)?.[1];
if (!certId) throw new Error("no cert id in buy output");
console.log(`purchased: ${certId}`);

// ---- 3. the NFT airdrop must be PENDING on the public mirror ----------------
const nft = await pollNft(certId, "pending");
console.log(`nft ${nft.token_id} serial ${nft.serial} state=${nft.claim_state}`);
const pendingUrl = `${MIRROR}/api/v1/accounts/${buyer}/airdrops/pending`;
await poll(async () => (await (await fetch(pendingUrl)).json()).airdrops?.length > 0, "mirror pending airdrop");
console.log(`PENDING on mirror: ${pendingUrl}`);

// ---- 4. the buyer's wallet claims it ---------------------------------------
const airdropId = new PendingAirdropId({})
  .setNftId(new NftId(TokenId.fromString(nft.token_id), nft.serial))
  .setSenderid(OPERATOR)
  .setReceiverId(buyer);
const claim = await (await (await new TokenClaimAirdropTransaction()
  .addPendingAirdropId(airdropId).freezeWith(client)).sign(buyerKey)).execute(client);
await claim.getReceipt(client);
console.log(`claimed: https://hashscan.io/testnet/transaction/${claim.transactionId.toString()}`);

// ---- 5. verify page / API now show claimed ---------------------------------
const after = await pollNft(certId, "claimed");
console.log(`\n=== CLAIM DEMO COMPLETE ===`);
console.log(`cert:    ${APP}/verify/${certId}`);
console.log(`nft:     https://hashscan.io/testnet/token/${after.token_id}/${after.serial} (owner ${buyer})`);
client.close();

// ---- helpers ----------------------------------------------------------------
function runBuy(accountId, key) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [ fileURLToPath(new URL("../buy.mjs", import.meta.url)),
      "--query", "snap cable clip", "--license", "commercial_unit" ],
      { env: { ...process.env, BUYER_ACCOUNT_ID: accountId, BUYER_PRIVATE_KEY: key } });
    let out = "";
    child.stdout.on("data", (c) => { out += c; });
    child.stderr.on("data", (c) => { out += c; });
    child.on("close", (code) => code === 0 ? resolve(out) : reject(new Error(`buy failed:\n${out}`)));
  });
}

async function pollNft(certId, want) {
  let nft;
  await poll(async () => {
    const cert = await (await fetch(`${APP}/api/v1/certificates/${certId}`)).json();
    nft = cert.nft;
    return nft && nft.claim_state === want;
  }, `nft ${want}`);
  return nft;
}

async function poll(ready, what, attempts = 30) {
  for (let i = 0; i < attempts; i++) {
    if (await ready().catch(() => false)) return;
    await new Promise((r) => setTimeout(r, 2000));
  }
  throw new Error(`timed out waiting for ${what}`);
}
