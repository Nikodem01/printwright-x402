#!/usr/bin/env node
// Printwright smoke gate: is the demo path alive, end to end, right now?
// Boot checks (app /up, sidecar /healthz, facilitator /supported), then one REAL
// x402 settle on Hedera testnet via scripts/buy.mjs, then independent confirmation
// that the license certificate anchored on the public mirror node.
// Exits non-zero on the first failure. Budget: under 2 minutes.
//
// Usage: node scripts/smoke.mjs
// Env:   PRINTWRIGHT_URL, HEDERA_SIDECAR_URL, X402_FACILITATOR_URL (defaults below)
//        BUYER_ACCOUNT_ID + BUYER_PRIVATE_KEY  (required — the paying account)
//        SMOKE_QUERY / SMOKE_LICENSE           (default: cheapest catalog offer)
import "dotenv/config";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const APP = (process.env.PRINTWRIGHT_URL || "http://localhost:3000").replace(/\/$/, "");
const SIDECAR = (process.env.HEDERA_SIDECAR_URL || "http://localhost:4021").replace(/\/$/, "");
const FACILITATOR = (process.env.X402_FACILITATOR_URL || "https://api.testnet.blocky402.com").replace(/\/$/, "");
const QUERY = process.env.SMOKE_QUERY || "snap cable clip";
const LICENSE = process.env.SMOKE_LICENSE || "commercial_unit";
const DEADLINE_MS = 120_000;
const BUY_SCRIPT = fileURLToPath(new URL("./buy.mjs", import.meta.url));

const started = Date.now();
const watchdog = setTimeout(() => fail(`smoke exceeded ${DEADLINE_MS / 1000}s`), DEADLINE_MS);

if (!process.env.BUYER_ACCOUNT_ID || !process.env.BUYER_PRIVATE_KEY) {
  fail("BUYER_ACCOUNT_ID and BUYER_PRIVATE_KEY must be set (the settle is real)");
}

// ---- 1. boot checks ---------------------------------------------------------
const upStatus = (await get(`${APP}/up`)).status;
if (upStatus !== 200) fail(`app: GET ${APP}/up -> ${upStatus} (start it: bin/dev)`);
ok(`app up (${APP})`);

const health = await getJson(`${SIDECAR}/healthz`, "sidecar (start it: node sidecar/server.mjs)");
if (health.ok !== true) fail(`sidecar unhealthy: ${JSON.stringify(health)}`);
if (!health.topicId) fail("sidecar has no HCS topic configured (HEDERA_HCS_TOPIC_ID)");
ok(`sidecar up (network ${health.network}, topic ${health.topicId})`);

const supported = await getJson(`${FACILITATOR}/supported`, "facilitator");
const NET = process.env.HEDERA_NETWORK === "mainnet" ? "mainnet" : "testnet";
const kind = (supported.kinds || []).find((k) => k.scheme === "exact" && k.network === `hedera:${NET}`);
if (!kind) fail(`facilitator does not list exact/hedera:${NET}: ${JSON.stringify(supported.kinds)}`);
ok(`facilitator supports exact/hedera:${NET} (feePayer ${kind.extra?.feePayer ?? "n/a"})`);

// ---- 2. one real settle via the demo buyer ---------------------------------
console.log(`\n-- settling for real: buy.mjs --query "${QUERY}" --license ${LICENSE}\n`);
const buy = await runBuy(["--query", QUERY, "--license", LICENSE]);
const certId = buy.match(/License:\s+(\S+)/)?.[1];
const settleUrl = buy.match(/Transaction:\s+(\S+)/)?.[1];
if (!certId) fail("could not find the license cert id in buy.mjs output");
ok(`settled — license ${certId}`);

// ---- 3. certificate anchored, confirmed on the public mirror ---------------
const cert = await waitAnchored(certId);
const mirror = await waitForMirror(cert.hcs.mirror_url);
if (!mirror.consensus_timestamp) fail(`mirror has no message at ${cert.hcs.mirror_url}`);
ok(`certificate anchored (topic ${cert.hcs.topic_id} seq ${cert.hcs.sequence_number}, consensus ${mirror.consensus_timestamp})`);

// ---- summary ----------------------------------------------------------------
clearTimeout(watchdog);
console.log(`\nSMOKE GREEN in ${((Date.now() - started) / 1000).toFixed(1)}s`);
console.log(`  settle tx:  ${settleUrl ?? "(see buy.mjs output above)"}`);
console.log(`  topic:      ${cert.hcs.hashscan_url}`);
console.log(`  mirror:     ${cert.hcs.mirror_url}`);
process.exit(0);

// ---- helpers ----------------------------------------------------------------

async function get(url) {
  try {
    return await fetch(url, { signal: AbortSignal.timeout(10_000), headers: { accept: "application/json" } });
  } catch (e) {
    fail(`GET ${url} failed: ${e.cause?.code ?? e.message}`);
  }
}

async function getJson(url, who = url) {
  const res = await get(url);
  if (!res.ok) fail(`${who}: GET ${url} -> ${res.status}`);
  return res.json();
}

function runBuy(args) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [BUY_SCRIPT, ...args], { env: process.env });
    let out = "";
    const tee = (chunk) => {
      out += chunk;
      process.stdout.write(chunk);
    };
    child.stdout.on("data", tee);
    child.stderr.on("data", tee);
    child.on("error", (e) => fail(`could not run buy.mjs: ${e.message}`));
    child.on("close", (code) => {
      if (code !== 0) fail(`buy.mjs exited ${code}`);
      resolve(out);
    });
  });
}

async function waitAnchored(certId) {
  for (;;) {
    const cert = await getJson(`${APP}/api/v1/certificates/${certId}`, "certificate api");
    if (cert.status === "anchored") return cert;
    await new Promise((r) => setTimeout(r, 2000));
  }
}

// "anchored" comes from the sidecar's receipt; the mirror node indexes a few
// seconds later. Retry so mirror lag reads as a wait, not a red.
async function waitForMirror(url) {
  for (;;) {
    const res = await get(url);
    if (res.ok) return res.json();
    if (res.status !== 404) fail(`mirror node: GET ${url} -> ${res.status}`);
    await new Promise((r) => setTimeout(r, 2000));
  }
}

function ok(msg) {
  console.log(`ok ${msg}`);
}

function fail(msg) {
  console.error(`\nSMOKE RED: ${msg}`);
  process.exit(1);
}
