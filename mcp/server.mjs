#!/usr/bin/env node
// Printwright MCP server: search, inspect, BUY (real testnet spend), verify.
// A thin wrapper over the public REST API — the same door any agent uses.
import "dotenv/config";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { PrintwrightClient } from "@printwright/client";
import { z } from "zod";

const BASE = (process.env.PRINTWRIGHT_URL || "http://localhost:3000").replace(/\/$/, "");
const NETWORK = process.env.HEDERA_NETWORK === "mainnet" ? "mainnet" : "testnet";
const client = new PrintwrightClient({
  baseUrl: BASE,
  accountId: process.env.BUYER_ACCOUNT_ID || process.env.HEDERA_ACCOUNT_ID,
  privateKey: process.env.BUYER_PRIVATE_KEY || process.env.HEDERA_PRIVATE_KEY,
  network: NETWORK,
});

// The spend cap is the only thing standing between an autonomous agent and an
// unbounded purchase, so a malformed value must never silently disable it:
// Number("abc") is NaN, and `price > NaN` is false, which would wave every
// offer through. Refuse to start instead.
export const MAX_SPEND_CENTS = parseSpendCap(process.env.MAX_SPEND_CENTS);

function parseSpendCap(raw) {
  if (raw === undefined || raw === "") return 500;
  const cap = Number(raw);
  if (!Number.isFinite(cap) || cap < 0) {
    console.error(`MAX_SPEND_CENTS must be a non-negative number of cents (got ${JSON.stringify(raw)})`);
    process.exit(1);
  }
  return cap;
}

const server = new McpServer({ name: "printwright", version: "0.1.0" });

const json = (data) => ({ content: [{ type: "text", text: JSON.stringify(data, null, 2) }] });
const fail = (message) => ({ isError: true, content: [{ type: "text", text: message }] });

server.registerTool(
  "search_models",
  {
    description: "Search the Printwright catalog of licensed 3D-printable models. " +
      "Returns id, title, prices in USD cents, and printability facts.",
    inputSchema: {
      query: z.string().describe("keywords, e.g. 'beaver hat'"),
      max_price_cents: z.number().int().optional(),
      material: z.string().optional().describe("e.g. PLA"),
      supports: z.boolean().optional().describe("filter by whether supports are required"),
    },
  },
  async ({ query, max_price_cents, material, supports }) => {
    const { models, count } = await client.search({
      query, maxPriceCents: max_price_cents, material, supports,
    });
    return json({
      count,
      models: models.map((m) => ({
        id: m.id, title: m.title, slug: m.slug,
        offers: m.license_offers, printability: m.printability,
      })),
    });
  }
);

server.registerTool(
  "get_model",
  {
    description: "Full metadata for one model: description, tags, file hash, license offers with terms.",
    inputSchema: { id: z.number().int() },
  },
  async ({ id }) => json(await client.get(id))
);

server.registerTool(
  "buy_license",
  {
    description: "Buy a print license for a model via x402. THIS SPENDS REAL HEDERA TESTNET " +
      `FUNDS (capped at MAX_SPEND_CENTS=${MAX_SPEND_CENTS}). Requires confirm: true. ` +
      "Returns the file download URLs, license serial, certificate id and HashScan link.",
    inputSchema: {
      model_id: z.number().int(),
      license: z.enum(["personal", "commercial_unit"]).default("personal"),
      asset: z.enum(["usdc", "hbar"]).optional(),
      confirm: z.boolean().describe("must be exactly true — this authorizes a real spend"),
    },
  },
  async ({ model_id, license, asset, confirm }) => {
    if (confirm !== true) {
      return fail("Refusing to buy: pass confirm: true after the user has approved the spend.");
    }
    const accountId = process.env.BUYER_ACCOUNT_ID || process.env.HEDERA_ACCOUNT_ID;
    const privateKey = process.env.BUYER_PRIVATE_KEY || process.env.HEDERA_PRIVATE_KEY;
    if (!accountId || !privateKey) return fail("BUYER_ACCOUNT_ID / BUYER_PRIVATE_KEY not configured.");

    const model = await client.get(model_id);
    const offer = model.license_offers.find((o) => o.kind === license);
    if (!offer) return fail(`model ${model_id} has no ${license} offer`);
    if (offer.price_cents > MAX_SPEND_CENTS) {
      return fail(`offer is ${offer.price_cents}c, over the MAX_SPEND_CENTS=${MAX_SPEND_CENTS} guardrail`);
    }

    const result = await client.buy({ modelId: model_id, license, asset });
    return json({
      files: result.files, license: result.license,
      cert_id: result.license.cert_id, verify_url: result.verify_url,
      transaction_id: result.transaction_id, hashscan_url: result.hashscan_url,
    });
  }
);

server.registerTool(
  "verify_certificate",
  {
    description: "Verify a license certificate: fetches our copy AND the on-chain HCS message " +
      "from the public mirror node, returns both plus match: true/false.",
    inputSchema: { cert_id: z.string().describe("e.g. pw-000003") },
  },
  async ({ cert_id }) => {
    const proof = await client.verify(cert_id);
    if (proof.status !== "anchored") proof.note = "not yet anchored on HCS — retry in a few seconds";
    else if (proof.match === null) proof.note ||= "HCS mirror indexing is still in progress — retry shortly";
    return json(proof);
  }
);

await server.connect(new StdioServerTransport());
console.error(`printwright mcp server ready (marketplace: ${BASE}, spend cap: ${MAX_SPEND_CENTS}c)`);
