#!/usr/bin/env node
// Printwright agent buyer: search -> 402 -> pay on Hedera testnet -> file + license certificate.
// No accounts, no cards, no browser — the whole purchase is one HTTP negotiation.
//
// Usage: node scripts/buy.mjs --query "beaver hat" [--license personal] [--asset usdc|hbar]
//                             [--max-price 300] [--dry-run] [--sandbox]
// Env:   PRINTWRIGHT_URL, BUYER_ACCOUNT_ID, BUYER_PRIVATE_KEY, HEDERA_NETWORK=testnet
import "dotenv/config";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { assets, PrintwrightClient } from "@printwright/client";

const NET = process.env.HEDERA_NETWORK === "mainnet" ? "mainnet" : "testnet";
const USDC = assets[NET].usdc;

const args = parseArgs(process.argv.slice(2));
const BASE = (process.env.PRINTWRIGHT_URL || "http://localhost:3000").replace(/\/$/, "");
const ACCOUNT_ID = process.env.BUYER_ACCOUNT_ID || process.env.HEDERA_ACCOUNT_ID;
const PRIVATE_KEY = process.env.BUYER_PRIVATE_KEY || process.env.HEDERA_PRIVATE_KEY;

if (!args.query) die("--query is required");
if (!args.dryRun && !args.sandbox && (!ACCOUNT_ID || !PRIVATE_KEY)) {
  die("BUYER_ACCOUNT_ID and BUYER_PRIVATE_KEY env vars are required to pay");
}
const printwright = new PrintwrightClient({
  baseUrl: BASE, accountId: ACCOUNT_ID, privateKey: PRIVATE_KEY, network: NET,
  sandbox: args.sandbox,
});

// ---- 1. search ------------------------------------------------------------
step(`searching for "${args.query}"`);
const search = await printwright.search({ query: args.query, maxPriceCents: args.maxPrice });
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
const quote = await printwright.quote({ modelId: model.id, license: args.license, asset: args.asset });
const paymentRequired402 = quote.paymentRequired;
console.log("   402 Payment Required — the server's PaymentRequired object:");
console.log(indent(JSON.stringify(paymentRequired402, null, 2), 3));

const accept = quote.accepted;
const assetLabel = args.sandbox ? "SANDBOX CREDIT (no funds)" : (accept.asset === USDC ? "USDC" : "HBAR");
console.log(`   paying with ${assetLabel}: ${accept.amount} base units -> ${accept.payTo}`);

if (args.dryRun) {
  step("--dry-run: stopping after the 402 (no payment made)");
  process.exit(0);
}

// ---- 3. associate if needed, sign & retry ---------------------------------
step(args.sandbox
  ? "sending the mock sandbox payment (no key, funds, or Hedera transaction)"
  : "associating USDC if needed, then signing + retrying (buyer signature only; facilitator pays fees)");
const body = await printwright.buy({ quote });

// ---- 5. deliverables ------------------------------------------------------
step(args.sandbox
  ? "sandbox simulation accepted locally — downloading the non-printable receipt"
  : "payment settled on Hedera — downloading deliverables");
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
console.log(`   Transaction: ${body.sandbox ? body.sandbox_url : body.hashscan_url}`);
console.log(`   Verify:      ${body.verify_url}`);
if (cert.hcs) {
  console.log(`   HCS topic:   ${cert.hcs.sandbox ? `${cert.hcs.topic_id} (LOCAL SANDBOX ONLY)` : cert.hcs.hashscan_url}`);
  console.log(`   Mirror node: ${cert.hcs.mirror_url}`);
}
console.log(body.sandbox
  ? "\ndone — SANDBOX rehearsal complete; no printable model or real license was issued."
  : "\ndone — licensed and ready to print.");

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
    else if (a === "--sandbox") out.sandbox = true;
    else if (a === "--help" || a === "-h") usage();
    else die(`unknown argument: ${a}`);
  }
  if (out.asset && ![ "usdc", "hbar" ].includes(out.asset)) die("--asset must be usdc or hbar");
  if (out.sandbox && out.asset) die("--sandbox uses fake sandbox credit; omit --asset");
  return out;
}

function pickOffer(model) {
  return model.license_offers.find((o) => o.kind === args.license) || model.license_offers[0];
}

function money(offer) {
  return `$${(offer.price_cents / 100).toFixed(2)} (${offer.currency}-lead)`;
}

async function waitForCertificate(certId, attempts = 10) {
  for (let i = 0; i < attempts; i++) {
    const cert = await printwright.verify(certId);
    if (["anchored", "sandbox"].includes(cert.status)) return cert;
    if (i === 0) step("waiting for the HCS certificate to anchor (mirror-node lag is a few seconds)");
    await new Promise((r) => setTimeout(r, 2000));
  }
  return printwright.verify(certId); // still minting — return as-is
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

function usage() {
  console.log(`Printwright agent buyer — search, pay over x402 on Hedera, get the file + license.

Usage: node scripts/buy.mjs --query "beaver hat" [options]

  --query <text>      what to search for (required)
  --license <kind>    license kind to buy (default: personal)
  --asset usdc|hbar   what to pay in (default: the offer's lead currency)
  --max-price <cents> skip anything dearer
  --dry-run           stop after the 402, pay nothing
  --sandbox           complete the fake end-to-end flow with no account or funds
  -h, --help          this message

Env: PRINTWRIGHT_URL (default http://localhost:3000), BUYER_ACCOUNT_ID,
     BUYER_PRIVATE_KEY, HEDERA_NETWORK (testnet|mainnet, default testnet).
     --dry-run needs no keys. Full API docs: <PRINTWRIGHT_URL>/docs`);
  process.exit(0);
}
