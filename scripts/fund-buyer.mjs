#!/usr/bin/env node
// Top up the demo buyer from the operator account. Testnet accounts drain
// after a run of demos; an empty buyer fails deep inside the facilitator as
// `invalid_exact_hedera_payload_preflight_failed`, which reads like a protocol
// bug. smoke.mjs now catches that case early — this is the fix it points to.
//
// Usage: node scripts/fund-buyer.mjs [--hbar 200] [--usdc 20] [--dry-run]
// Env:   HEDERA_ACCOUNT_ID + HEDERA_PRIVATE_KEY (operator, the source),
//        BUYER_ACCOUNT_ID (the destination), HEDERA_NETWORK=testnet|mainnet
import "dotenv/config";
import { Client, AccountId, PrivateKey, TransferTransaction, Hbar } from "@hiero-ledger/sdk";

const NET = process.env.HEDERA_NETWORK === "mainnet" ? "mainnet" : "testnet";
const USDC = NET === "mainnet" ? "0.0.456858" : "0.0.429274";
const MIRROR = process.env.MIRROR_NODE_URL || `https://${NET}.mirrornode.hedera.com`;

const args = process.argv.slice(2);
const flag = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  return i === -1 ? fallback : Number(args[i + 1]);
};
const hbar = flag("hbar", 200);
const usdc = flag("usdc", 20);
const dryRun = args.includes("--dry-run");

const from = process.env.HEDERA_ACCOUNT_ID;
const to = process.env.BUYER_ACCOUNT_ID;
const key = process.env.HEDERA_PRIVATE_KEY;
if (!from || !to || !key) die("HEDERA_ACCOUNT_ID, HEDERA_PRIVATE_KEY and BUYER_ACCOUNT_ID are required");
if (from === to) die(`operator and buyer are the same account (${from}) — nothing to move`);
if (!(hbar >= 0) || !(usdc >= 0)) die("--hbar and --usdc must be non-negative numbers");

console.log(`funding ${to} from ${from} on ${NET}: ${hbar} ℏ + ${usdc} USDC`);
await report("before");

if (dryRun) {
  console.log("--dry-run: nothing sent");
  process.exit(0);
}

const client = Client.forName(NET).setOperator(AccountId.fromString(from), PrivateKey.fromStringECDSA(key));
const tx = new TransferTransaction().setTransactionMemo("printwright: fund demo buyer");
if (hbar > 0) tx.addHbarTransfer(from, new Hbar(-hbar)).addHbarTransfer(to, new Hbar(hbar));
if (usdc > 0) {
  const units = Math.round(usdc * 1e6);
  tx.addTokenTransfer(USDC, from, -units).addTokenTransfer(USDC, to, units);
}

try {
  const sent = await tx.execute(client);
  const receipt = await sent.getReceipt(client);
  console.log(`\n${receipt.status.toString()} — ${sent.transactionId.toString()}`);
  console.log(`https://hashscan.io/${NET}/transaction/${sent.transactionId.toString()}`);
} catch (e) {
  // TOKEN_NOT_ASSOCIATED_TO_ACCOUNT is the one everybody hits: a fresh buyer
  // must associate USDC before it can receive any.
  die(`${e.message}\n(if this is TOKEN_NOT_ASSOCIATED_TO_ACCOUNT, the buyer must associate ${USDC} first — scripts/buy.mjs does this automatically on its first USDC purchase)`);
} finally {
  client.close();
}

await report("after");

async function report(label) {
  const res = await fetch(`${MIRROR}/api/v1/accounts/${to}`);
  if (!res.ok) return console.log(`  (${label}: mirror returned ${res.status})`);
  const { balance } = await res.json();
  const held = (balance.tokens || []).find((t) => t.token_id === USDC)?.balance ?? 0;
  console.log(`  ${label}: ${(balance.balance / 1e8).toFixed(2)} ℏ · ${(held / 1e6).toFixed(2)} USDC`);
}

function die(msg) {
  console.error(`\nerror: ${msg}`);
  process.exit(1);
}
