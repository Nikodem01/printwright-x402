#!/usr/bin/env node
// Printwright agent buyer: search -> 402 -> pay on Hedera testnet -> file + license certificate.
// No accounts, no cards, no browser — the whole purchase is one HTTP negotiation.
//
// Usage: node scripts/buy.mjs --query "beaver hat" [--license personal] [--asset usdc|hbar]
//                             [--max-price 300] [--dry-run]
// Env:   PRINTWRIGHT_URL, BUYER_ACCOUNT_ID, BUYER_PRIVATE_KEY, HEDERA_NETWORK=testnet
import "dotenv/config";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { x402Client, x402HTTPClient } from "@x402/core/client";
import { createClientHederaSigner, PrivateKey } from "@x402/hedera";
import { ExactHederaScheme } from "@x402/hedera/exact/client";
import {
  Client as HederaClient,
  TokenAssociateTransaction,
} from "@hiero-ledger/sdk";

const USDC = "0.0.429274";
const ASSET_IDS = { usdc: USDC, hbar: "0.0.0" };

const args = parseArgs(process.argv.slice(2));
const BASE = (process.env.PRINTWRIGHT_URL || "http://localhost:3000").replace(/\/$/, "");
const ACCOUNT_ID = process.env.BUYER_ACCOUNT_ID || process.env.HEDERA_ACCOUNT_ID;
const PRIVATE_KEY = process.env.BUYER_PRIVATE_KEY || process.env.HEDERA_PRIVATE_KEY;

if (!args.query) die("--query is required");
if (!args.dryRun && (!ACCOUNT_ID || !PRIVATE_KEY)) {
  die("BUYER_ACCOUNT_ID and BUYER_PRIVATE_KEY env vars are required to pay");
}

// ---- 1. search ------------------------------------------------------------
step(`searching for "${args.query}"`);
const searchParams = new URLSearchParams({ q: args.query });
if (args.maxPrice) searchParams.set("max_price_cents", args.maxPrice);
const search = await getJson(`${BASE}/api/v1/models?${searchParams}`);
if (search.count === 0) die("no models matched");

for (const m of search.models.slice(0, 5)) {
  const offer = pickOffer(m);
  console.log(`   ${String(m.id).padStart(4)}  ${m.title.padEnd(40)} ${money(offer)}`);
}
const model = search.models[0];
const offer = pickOffer(model);
if (args.maxPrice && offer.price_cents > args.maxPrice) die("top result exceeds --max-price");
console.log(`   -> buying #${model.id} "${model.title}" (${args.license}, ${money(offer)})`);

// ---- 2. hit the paywall ---------------------------------------------------
const resourceUrl = `${BASE}/api/v1/models/${model.id}/download?license=${args.license}`;
step(`GET ${resourceUrl}`);
const leg1 = await fetch(resourceUrl, { headers: { accept: "application/json" } });
if (leg1.status !== 402) die(`expected 402 Payment Required, got ${leg1.status}: ${await leg1.text()}`);
const paymentRequired402 = await leg1.json();
console.log("   402 Payment Required — the server's PaymentRequired object:");
console.log(indent(JSON.stringify(paymentRequired402, null, 2), 3));

const wanted = args.asset ? ASSET_IDS[args.asset] : paymentRequired402.accepts[0].asset;
const accept = paymentRequired402.accepts.find((a) => a.asset === wanted);
if (!accept) die(`server does not accept asset "${args.asset}"`);
console.log(`   paying with ${accept.asset === USDC ? "USDC" : "HBAR"}: ${accept.amount} base units -> ${accept.payTo}`);

if (args.dryRun) {
  step("--dry-run: stopping after the 402 (no payment made)");
  process.exit(0);
}

// ---- 3. USDC association (first run only) ---------------------------------
if (accept.asset === USDC) await ensureAssociated();

// ---- 4. sign & retry ------------------------------------------------------
step("building + signing the TransferTransaction (buyer signature only; facilitator pays fees)");
const signer = createClientHederaSigner(ACCOUNT_ID, PrivateKey.fromStringECDSA(PRIVATE_KEY), {
  network: process.env.HEDERA_NETWORK === "mainnet" ? "hedera:mainnet" : "hedera:testnet",
});
const httpClient = new x402HTTPClient(new x402Client().register("hedera:*", new ExactHederaScheme(signer)));
const paymentRequired = httpClient.getPaymentRequiredResponse((n) => leg1.headers.get(n), paymentRequired402);
const payload = await httpClient.createPaymentPayload({ ...paymentRequired, accepts: [accept] });
const headers = httpClient.encodePaymentSignatureHeader(payload);

step("retrying with the signed payment attached");
const leg2 = await fetch(resourceUrl, { headers: { accept: "application/json", ...headers } });
const body = await leg2.json();
if (leg2.status !== 200) die(`payment failed (${leg2.status}): ${JSON.stringify(body)}`);

// ---- 5. deliverables ------------------------------------------------------
step("payment settled on Hedera — downloading deliverables");
const dir = join("purchases", model.slug);
mkdirSync(dir, { recursive: true });
for (const file of body.files) {
  const res = await fetch(file.url);
  if (!res.ok) die(`file download failed: ${res.status}`);
  const path = join(dir, `${model.slug}.${file.kind}`);
  writeFileSync(path, Buffer.from(await res.arrayBuffer()));
  console.log(`   file:        ${path}`);
}

const cert = await waitForCertificate(body.license.cert_id);
writeFileSync(join(dir, "certificate.json"), JSON.stringify(cert, null, 2));
console.log(`   certificate: ${join(dir, "certificate.json")} (${cert.status})`);

console.log(`\n   License:     ${body.license.cert_id} — ${body.license.kind}, unit serial ${body.license.serial}`);
console.log(`   Transaction: ${body.hashscan_url}`);
console.log(`   Verify:      ${body.verify_url}`);
if (cert.hcs) {
  console.log(`   HCS topic:   ${cert.hcs.hashscan_url}`);
  console.log(`   Mirror node: ${cert.hcs.mirror_url}`);
}
console.log("\ndone — licensed and ready to print.");

// ---- helpers ---------------------------------------------------------------

function parseArgs(argv) {
  const out = { license: "personal", dryRun: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--query") out.query = argv[++i];
    else if (a === "--license") out.license = argv[++i];
    else if (a === "--asset") out.asset = argv[++i]?.toLowerCase();
    else if (a === "--max-price") out.maxPrice = Number(argv[++i]);
    else if (a === "--dry-run") out.dryRun = true;
    else die(`unknown argument: ${a}`);
  }
  if (out.asset && !ASSET_IDS[out.asset]) die("--asset must be usdc or hbar");
  return out;
}

function pickOffer(model) {
  return model.license_offers.find((o) => o.kind === args.license) || model.license_offers[0];
}

function money(offer) {
  return `$${(offer.price_cents / 100).toFixed(2)} (${offer.currency}-lead)`;
}

async function getJson(url) {
  const res = await fetch(url, { headers: { accept: "application/json" } });
  if (!res.ok) die(`GET ${url} -> ${res.status}`);
  return res.json();
}

async function ensureAssociated() {
  const mirror = `https://testnet.mirrornode.hedera.com/api/v1/accounts/${ACCOUNT_ID}/tokens?token.id=${USDC}`;
  const { tokens } = await getJson(mirror);
  if (tokens?.length) return;
  step(`associating ${ACCOUNT_ID} with testnet USDC (one-time)`);
  const client = HederaClient.forTestnet().setOperator(ACCOUNT_ID, PrivateKey.fromStringECDSA(PRIVATE_KEY));
  const response = await new TokenAssociateTransaction()
    .setAccountId(ACCOUNT_ID).setTokenIds([USDC]).execute(client);
  await response.getReceipt(client);
  console.log(`   associated: ${response.transactionId.toString()}`);
  client.close();
}

async function waitForCertificate(certId, attempts = 10) {
  for (let i = 0; i < attempts; i++) {
    const cert = await getJson(`${BASE}/api/v1/certificates/${certId}`);
    if (cert.status === "anchored") return cert;
    if (i === 0) step("waiting for the HCS certificate to anchor (mirror-node lag is a few seconds)");
    await new Promise((r) => setTimeout(r, 2000));
  }
  return getJson(`${BASE}/api/v1/certificates/${certId}`); // still minting — return as-is
}

function step(msg) {
  console.log(`\n=> ${msg}`);
}

function indent(text, n) {
  return text.split("\n").map((l) => " ".repeat(n) + l).join("\n");
}

function die(msg) {
  console.error(`\nerror: ${msg}`);
  process.exit(1);
}
