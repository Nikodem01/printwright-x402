#!/usr/bin/env node
import { performance } from "node:perf_hooks";
import { fileURLToPath } from "node:url";

const defaults = { requests: 100, concurrency: 10, timeoutMs: 10_000, path: "/api/v1/models" };

export async function runLoadSanity(options) {
  const target = targetUrl(options.baseUrl, options.path);
  const latencies = [];
  const statuses = new Map();
  const errors = [];
  let next = 0;

  const warmup = await fetch(target, {
    headers: { accept: "application/json", "user-agent": "printwright-load-sanity/0.1" },
    signal: AbortSignal.timeout(options.timeoutMs)
  });
  await warmup.arrayBuffer();
  if (!warmup.ok) throw new Error(`warm-up GET returned ${warmup.status}`);

  const started = performance.now();
  await Promise.all(Array.from({ length: options.concurrency }, async () => {
    while (next < options.requests) {
      const requestNumber = next++;
      const requestStarted = performance.now();
      try {
        const response = await fetch(target, {
          headers: { accept: "application/json", "user-agent": "printwright-load-sanity/0.1" },
          signal: AbortSignal.timeout(options.timeoutMs)
        });
        await response.arrayBuffer();
        latencies.push(performance.now() - requestStarted);
        statuses.set(response.status, (statuses.get(response.status) || 0) + 1);
      } catch (error) {
        errors.push({ request: requestNumber + 1, error: error.cause?.code || error.name || error.message });
      }
    }
  }));
  const durationMs = performance.now() - started;
  latencies.sort((a, b) => a - b);

  return {
    target,
    warmup_status: warmup.status,
    requests: options.requests,
    concurrency: options.concurrency,
    duration_ms: rounded(durationMs),
    requests_per_second: rounded(options.requests / (durationMs / 1_000)),
    latency_ms: {
      min: percentile(latencies, 0),
      p50: percentile(latencies, 50),
      p95: percentile(latencies, 95),
      p99: percentile(latencies, 99),
      max: percentile(latencies, 100)
    },
    statuses: Object.fromEntries([...statuses.entries()].sort(([a], [b]) => a - b)),
    errors
  };
}

export function parseArgs(argv, env = process.env) {
  const options = { ...defaults, baseUrl: env.PRINTWRIGHT_URL, json: false };
  for (let i = 0; i < argv.length; i += 1) {
    const argument = argv[i];
    if (argument === "--url") options.baseUrl = argv[++i];
    else if (argument === "--path") options.path = argv[++i];
    else if (argument === "--requests") options.requests = integer(argv[++i], "requests", 1, 10_000);
    else if (argument === "--concurrency") options.concurrency = integer(argv[++i], "concurrency", 1, 200);
    else if (argument === "--timeout-ms") options.timeoutMs = integer(argv[++i], "timeout-ms", 100, 60_000);
    else if (argument === "--json") options.json = true;
    else if (argument === "--help") return { help: true };
    else throw new Error(`unknown argument: ${argument}`);
  }

  if (!options.baseUrl) throw new Error("--url or PRINTWRIGHT_URL is required");
  if (!options.path?.startsWith("/") || options.path.startsWith("//")) {
    throw new Error("--path must be a relative path beginning with /");
  }
  const base = new URL(options.baseUrl);
  const local = [ "localhost", "127.0.0.1", "::1" ].includes(base.hostname);
  if (base.protocol !== "https:" && !(local && base.protocol === "http:")) {
    throw new Error("non-local load targets must use https");
  }
  return options;
}

function targetUrl(baseUrl, path) {
  const base = new URL(baseUrl);
  base.pathname = path;
  base.search = "";
  base.hash = "";
  return base.toString();
}

function integer(value, name, min, max) {
  if (!/^\d+$/.test(value || "")) throw new Error(`--${name} must be an integer`);
  const parsed = Number(value);
  if (parsed < min || parsed > max) throw new Error(`--${name} must be between ${min} and ${max}`);
  return parsed;
}

function percentile(sorted, wanted) {
  if (sorted.length === 0) return null;
  const index = Math.ceil((wanted / 100) * sorted.length) - 1;
  return rounded(sorted[Math.max(0, index)]);
}

function rounded(value) {
  return Math.round(value * 100) / 100;
}

function printHuman(result) {
  console.log(`Load sanity: ${result.target}`);
  console.log(`Warm-up status: ${result.warmup_status}`);
  console.log(`${result.requests} requests at concurrency ${result.concurrency} in ${result.duration_ms} ms`);
  console.log(`Throughput: ${result.requests_per_second} req/s`);
  console.log(`Latency ms: min ${result.latency_ms.min} | p50 ${result.latency_ms.p50} | p95 ${result.latency_ms.p95} | p99 ${result.latency_ms.p99} | max ${result.latency_ms.max}`);
  console.log(`Statuses: ${JSON.stringify(result.statuses)} | transport errors: ${result.errors.length}`);
}

function usage() {
  console.log("Usage: node scripts/load-sanity.mjs --url https://market.example [options]");
  console.log("Options: --path /api/v1/models --requests 100 --concurrency 10 --timeout-ms 10000 --json");
  console.log("Read-only GET requests only. Non-local targets must use HTTPS.");
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  try {
    const options = parseArgs(process.argv.slice(2));
    if (options.help) {
      usage();
      process.exit(0);
    }
    const result = await runLoadSanity(options);
    if (options.json) console.log(JSON.stringify(result));
    else printHuman(result);

    const failedStatuses = Object.keys(result.statuses).filter((status) => !status.startsWith("2"));
    if (result.errors.length > 0 || failedStatuses.length > 0) process.exitCode = 1;
  } catch (error) {
    console.error(`load sanity failed: ${error.message}`);
    usage();
    process.exitCode = 1;
  }
}
