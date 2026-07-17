#!/usr/bin/env node
// Scene 3: a print server that pays its own royalties. Every job start buys a
// commercial per-unit license over x402 — machine-speed, sub-$1, no human, no
// card — and gets back a public certificate for the unit it is about to print.
//
// Usage: node scripts/print-job.mjs --qty 3 [--query "snap cable clip"]
// Env:   PRINTWRIGHT_URL, BUYER_ACCOUNT_ID, BUYER_PRIVATE_KEY
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const args = process.argv.slice(2);
const qty = Number(args[args.indexOf("--qty") + 1] || 3);
const queryIdx = args.indexOf("--query");
const query = queryIdx >= 0 ? args[queryIdx + 1] : "snap cable clip";
const BUY = fileURLToPath(new URL("./buy.mjs", import.meta.url));

console.log(`printwright print server — run of ${qty} unit(s) of "${query}"`);
console.log("each job start pays the designer's per-unit royalty over x402\n");

const units = [];
for (let job = 1; job <= qty; job++) {
  console.log(`── job ${job}/${qty}: heating bed, paying royalty before first layer…`);
  const out = await run();
  const unit = {
    license: out.match(/License:\s+(\S+)/)?.[1],
    serial: out.match(/unit serial (\d+)/)?.[1],
    settle: out.match(/Transaction:\s+(\S+)/)?.[1],
    mirror: out.match(/Mirror node:\s+(\S+)/)?.[1],
  };
  if (!unit.license || !unit.settle) {
    console.error(out);
    throw new Error(`job ${job}: purchase failed`);
  }
  units.push(unit);
  console.log(`   licensed unit #${unit.serial} — ${unit.license}`);
  console.log(`   royalty settled: ${unit.settle}`);
  console.log(`   printing… done. certificate anchored: ${unit.mirror}\n`);
}

console.log(`═══ run complete: ${qty} unit(s), ${qty} royalties, ${qty} public certificates`);
for (const unit of units) {
  console.log(`  ${unit.license}  ${unit.settle}`);
}
console.log("every unit above is provably licensed — check any of them on the mirror.");

function run() {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [ BUY, "--query", query, "--license", "commercial_unit" ], { env: process.env });
    let out = "";
    child.stdout.on("data", (c) => { out += c; });
    child.stderr.on("data", (c) => { out += c; });
    child.on("close", (code) => (code === 0 ? resolve(out) : reject(new Error(`buy.mjs exited ${code}:\n${out}`))));
  });
}
