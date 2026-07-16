// V2 kill-test (C1): can an HTS NFT carry the license story end to end?
// collection (with designer royalty) -> mint -> airdrop to a fresh 0-slot account
// -> pending visible on mirror -> claim -> secondary transfer fires the royalty.
// Everything runs on real testnet; every step prints a HashScan/mirror link.
//
// Usage: HEDERA_ACCOUNT_ID=0.0.x HEDERA_PRIVATE_KEY=0x... node scripts/spike/hts-nft.mjs
import "dotenv/config";
import {
  AccountCreateTransaction,
  AccountId,
  Client,
  CustomRoyaltyFee,
  Hbar,
  PrivateKey,
  TokenAirdropTransaction,
  TokenClaimAirdropTransaction,
  TokenCreateTransaction,
  TokenMintTransaction,
  TokenSupplyType,
  TokenType,
  TransferTransaction,
} from "@hiero-ledger/sdk";

const OPERATOR_ID = process.env.HEDERA_ACCOUNT_ID;
const OPERATOR_KEY = process.env.HEDERA_PRIVATE_KEY;
const ROYALTY_COLLECTOR = process.env.SPIKE_ROYALTY_COLLECTOR || "0.0.9584959"; // designer stand-in
const MIRROR = "https://testnet.mirrornode.hedera.com";
if (!OPERATOR_ID || !OPERATOR_KEY) throw new Error("HEDERA_ACCOUNT_ID and HEDERA_PRIVATE_KEY required");

const operatorId = AccountId.fromString(OPERATOR_ID);
const operatorKey = PrivateKey.fromStringECDSA(OPERATOR_KEY);
const client = Client.forTestnet().setOperator(operatorId, operatorKey);
const links = [];

// ---- 1. collection with a 10% designer royalty ------------------------------
// NO fallback fee: the network rejects airdrops of fallback-royalty NFTs
// (TOKEN_AIRDROP_WITH_FALLBACK_ROYALTY, found empirically on the first run).
// Royalty still fires whenever the NFT moves against fungible value.
const royalty = new CustomRoyaltyFee()
  .setFeeCollectorAccountId(ROYALTY_COLLECTOR)
  .setNumerator(10)
  .setDenominator(100);

const createRx = await (
  await new TokenCreateTransaction()
    .setTokenName("Printwright License Spike")
    .setTokenSymbol("PWLS")
    .setTokenType(TokenType.NonFungibleUnique)
    .setSupplyType(TokenSupplyType.Finite)
    .setMaxSupply(100)
    .setTreasuryAccountId(operatorId)
    .setSupplyKey(operatorKey)
    .setAdminKey(operatorKey)
    .setCustomFees([royalty])
    .execute(client)
).getReceipt(client);
const tokenId = createRx.tokenId;
step(`collection ${tokenId} created (10% royalty -> ${ROYALTY_COLLECTOR}, no fallback)`,
  `https://hashscan.io/testnet/token/${tokenId}`);

// ---- 2. mint one license serial ---------------------------------------------
const mintResp = await new TokenMintTransaction()
  .setTokenId(tokenId)
  .addMetadata(Buffer.from("printwright-spike:cert:pw-000008"))
  .execute(client);
const { serials } = await mintResp.getReceipt(client);
const serial = serials[0];
step(`minted serial ${serial}`, hashscanTx(mintResp.transactionId));

// ---- 3. fresh 0-slot account (the buyer who never associated) ---------------
const buyerKey = PrivateKey.generateECDSA();
const acctResp = await new AccountCreateTransaction()
  .setECDSAKeyWithAlias(buyerKey)
  .setInitialBalance(new Hbar(5))
  .setMaxAutomaticTokenAssociations(0)
  .execute(client);
const buyerId = (await acctResp.getReceipt(client)).accountId;
step(`fresh 0-slot account ${buyerId} created`, hashscanTx(acctResp.transactionId));

// ---- 4. airdrop the NFT -> must go pending -----------------------------------
const airdropResp = await new TokenAirdropTransaction()
  .addNftTransfer(tokenId, serial, operatorId, buyerId)
  .execute(client);
const airdropRecord = await airdropResp.getRecord(client);
const pending = airdropRecord.newPendingAirdrops;
if (!pending?.length) die("airdrop did NOT go pending — 0-slot assumption is wrong");
step(`airdrop pending (not yet owned) — pendingAirdropId captured`, hashscanTx(airdropResp.transactionId));

// ---- 5. pending airdrop visible on the public mirror -------------------------
const pendingUrl = `${MIRROR}/api/v1/accounts/${buyerId}/airdrops/pending`;
const seen = await pollMirror(pendingUrl, (b) => b.airdrops?.length > 0);
if (!seen) die(`mirror never showed the pending airdrop at ${pendingUrl}`);
step(`pending airdrop visible on mirror`, pendingUrl);

// ---- 6. buyer claims ----------------------------------------------------------
const claimResp = await (
  await (
    await new TokenClaimAirdropTransaction()
      .addPendingAirdropId(pending[0].airdropId)
      .freezeWith(client)
  ).sign(buyerKey)
).execute(client);
await claimResp.getReceipt(client);
step(`buyer claimed — NFT now owned by ${buyerId}`, hashscanTx(claimResp.transactionId));

// ---- 7. secondary sale: royalty must fire ------------------------------------
// buyer sells the NFT back to operator for 2 hbar; 10% (0.2 hbar) must route to the collector.
const saleResp = await (
  await (
    await new TransferTransaction()
      .addNftTransfer(tokenId, serial, buyerId, operatorId)
      .addHbarTransfer(operatorId, new Hbar(-2))
      .addHbarTransfer(buyerId, new Hbar(2))
      .freezeWith(client)
  ).sign(buyerKey)
).execute(client);
await saleResp.getReceipt(client);
const saleTxId = saleResp.transactionId;
step(`secondary sale executed`, hashscanTx(saleTxId));

// confirm the assessed royalty on the mirror record
const mirrorTxUrl = `${MIRROR}/api/v1/transactions/${mirrorTxId(saleTxId)}`;
const saleTx = await pollMirror(mirrorTxUrl, (b) => b.transactions?.length > 0);
if (!saleTx) die(`mirror never showed the sale tx at ${mirrorTxUrl}`);
const fees = saleTx.transactions[0].assessed_custom_fees ?? [];
const royaltyHit = fees.find((f) => f.collector_account_id === ROYALTY_COLLECTOR);
if (!royaltyHit) die(`no assessed royalty to ${ROYALTY_COLLECTOR}: ${JSON.stringify(fees)}`);
step(`royalty assessed: ${royaltyHit.amount} tinybar -> ${ROYALTY_COLLECTOR}`, mirrorTxUrl);

client.close();
console.log("\n=== V2 HTS NFT kill-test: GO ===");
for (const l of links) console.log(`  ${l}`);

// ---- helpers ------------------------------------------------------------------
function step(msg, link) {
  console.log(`\nok ${msg}\n   ${link}`);
  links.push(link);
}
function hashscanTx(txId) {
  return `https://hashscan.io/testnet/transaction/${txId.toString()}`;
}
function mirrorTxId(txId) {
  // 0.0.x@sec.nanos -> 0.0.x-sec-nanos (mirror node format)
  const [payer, ts] = txId.toString().split("@");
  return `${payer}-${ts.replace(".", "-")}`;
}
async function pollMirror(url, ready, attempts = 15) {
  for (let i = 0; i < attempts; i++) {
    const res = await fetch(url);
    if (res.ok) {
      const body = await res.json();
      if (ready(body)) return body;
    }
    await new Promise((r) => setTimeout(r, 2000));
  }
  return null;
}
function die(msg) {
  client.close();
  console.error(`\n=== V2 HTS NFT kill-test: NO-GO — ${msg}`);
  process.exit(1);
}
