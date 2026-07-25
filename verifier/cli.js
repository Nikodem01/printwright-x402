#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import { VerificationError, verifyBundle } from "./index.js";

const usage = `Usage: printwright-verify <bundle.json | url | ->  [--json]

Verify a Printwright license certificate from its proof bundle. The bundle is
the reveal of an opaque on-chain commitment; this tool recomputes the commitment
locally (RFC 8785 JCS + SHA-256) and confirms it matches the message anchored on
a public Hedera mirror node — trusting neither Printwright's servers nor verdict.

Input:
  <bundle.json>   a proof-bundle file (from your paid delivery)
  <https url>     a bundle_url to fetch (e.g. the certificates API)
  -               read the bundle from stdin

Options:
  --json          print the full result as JSON
  --help          show this help

Note: Hedera proves the certificate bytes were committed no later than the
consensus timestamp — not that every assertion inside them is true.`;

const LABELS = {
  bundle_integrity: "bundle integrity",
  certificate_schema: "certificate schema",
  terms_integrity: "terms integrity",
  hedera_anchoring: "Hedera anchoring",
  issuer_assertions: "issuer assertions",
};

try {
  const options = parseArguments(process.argv.slice(2));
  if (options.help) {
    console.log(usage);
    process.exit(0);
  }
  const bundle = await loadBundle(options.input);
  const result = await verifyBundle(bundle, options);

  if (options.json) {
    console.log(JSON.stringify(result, null, 2));
  } else {
    printResult(result);
  }
  process.exit(result.verified ? 0 : 2);
} catch (error) {
  const code = error instanceof VerificationError ? error.code : "unexpected_error";
  console.error(`✗ ${code}: ${error.message}`);
  process.exit(1);
}

function printResult(result) {
  console.log(`Certificate ${result.cert_id}`);
  for (const [ key, label ] of Object.entries(LABELS)) {
    console.log(`  ${label.padEnd(19)} ${describe(key, result)}`);
  }
  console.log(result.verified ? "\n=> VERIFIED" : "\n=> NOT VERIFIED");
}

function describe(key, result) {
  const state = result.checks[key];
  if (key === "issuer_assertions") {
    return "not independently proven — the ledger proves commitment timing, not truth";
  }
  if (key === "hedera_anchoring") {
    if (state === "verified") {
      return `VERIFIED  (topic ${result.topic_id} seq ${result.sequence_number}, consensus ${result.consensus_timestamp})`;
    }
    if (state === "pending") return "PENDING  (commitment not yet anchored — retry shortly)";
  }
  if (key === "certificate_schema" && state === "failed") {
    return `FAILED  (${result.certificate_errors.join("; ")})`;
  }
  return state.toUpperCase();
}

async function loadBundle(input) {
  let text;
  if (input === "-") {
    text = await readStdin();
  } else if (/^https?:\/\//.test(input)) {
    const response = await fetch(input, {
      headers: { accept: "application/json" },
      signal: AbortSignal.timeout(10_000),
    }).catch((error) => {
      throw new VerificationError(`could not fetch bundle: ${error.message}`, "mirror_unavailable");
    });
    if (!response.ok) throw new VerificationError(`bundle URL returned HTTP ${response.status}`, "invalid_input");
    text = await response.text();
  } else {
    text = await readFile(input, "utf8").catch((error) => {
      throw new VerificationError(`could not read ${input}: ${error.message}`, "invalid_input");
    });
  }
  try {
    return JSON.parse(text);
  } catch {
    throw new VerificationError("input is not valid JSON", "invalid_input");
  }
}

function readStdin() {
  return new Promise((resolve, reject) => {
    let data = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => { data += chunk; });
    process.stdin.on("end", () => resolve(data));
    process.stdin.on("error", reject);
  });
}

function parseArguments(args) {
  if (args.includes("--help") || args.includes("-h")) return { help: true };
  const options = { json: false };
  const positional = [];
  for (const argument of args) {
    if (argument === "--json") {
      options.json = true;
    } else if (argument === "-") {
      positional.push(argument);
    } else if (argument.startsWith("--")) {
      throw new VerificationError(`unknown option ${argument}`, "invalid_input");
    } else {
      positional.push(argument);
    }
  }
  if (positional.length !== 1) {
    throw new VerificationError("provide exactly one bundle file, url, or - for stdin", "invalid_input");
  }
  options.input = positional[0];
  return options;
}
