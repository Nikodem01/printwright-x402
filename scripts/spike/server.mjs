// Minimal x402 resource server: one paid route, GET /premium, priced in HBAR.
// Uses the official @x402/core resource server + @x402/hedera exact scheme,
// with the facilitator reached through the logging proxy (facilitator-proxy.mjs).
// All inbound requests and outbound responses are captured in wire-log/server.jsonl.
import "dotenv/config";
import http from "node:http";
import { x402ResourceServer } from "@x402/core/server";
import { HTTPFacilitatorClient, x402HTTPResourceServer } from "@x402/core/http";
import { ExactHederaScheme } from "@x402/hedera/exact/server";
import { wireLog } from "./wirelog.mjs";

const PORT = Number(process.env.SERVER_PORT || 4402);
const FACILITATOR_URL = process.env.SERVER_FACILITATOR_URL || "http://127.0.0.1:4403";
const PAY_TO = process.env.TREASURY_ACCOUNT_ID;
if (!PAY_TO) throw new Error("TREASURY_ACCOUNT_ID missing — run create-treasury.mjs first");

const PRICE_TINYBARS = "10000000"; // 0.1 HBAR

const facilitator = new HTTPFacilitatorClient({ url: FACILITATOR_URL });
const core = new x402ResourceServer(facilitator).register("hedera:*", new ExactHederaScheme());

const routes = {
  "GET /premium": {
    accepts: {
      scheme: "exact",
      network: "hedera:testnet",
      payTo: PAY_TO,
      price: { asset: "0.0.0", amount: PRICE_TINYBARS },
      maxTimeoutSeconds: 180,
    },
    description: "Spike: premium JSON behind an x402 HBAR paywall",
    mimeType: "application/json",
  },
};

const server = new x402HTTPResourceServer(core, routes);
await server.initialize();

function adapterFor(req, url) {
  return {
    getHeader: (name) => req.headers[name.toLowerCase()],
    getMethod: () => req.method,
    getPath: () => url.pathname,
    getUrl: () => `http://${req.headers.host}${req.url}`,
    getAcceptHeader: () => req.headers.accept || "application/json",
    getUserAgent: () => req.headers["user-agent"] || "",
    getQueryParams: () => Object.fromEntries(url.searchParams),
    getQueryParam: (name) => url.searchParams.get(name) ?? undefined,
  };
}

function respond(req, res, status, headers, bodyObject) {
  const body = typeof bodyObject === "string" ? bodyObject : JSON.stringify(bodyObject, null, 2);
  wireLog("server.jsonl", {
    method: req.method,
    path: req.url,
    requestHeaders: req.headers,
    status,
    responseHeaders: headers,
    responseBody: body,
  });
  res.writeHead(status, { "content-type": "application/json", ...headers });
  res.end(body);
}

http
  .createServer(async (req, res) => {
    const url = new URL(req.url, `http://${req.headers.host}`);
    try {
      const result = await server.processHTTPRequest({
        adapter: adapterFor(req, url),
        path: url.pathname,
        method: req.method,
      });

      if (result.type === "no-payment-required") {
        return respond(req, res, 200, {}, { free: true });
      }
      if (result.type === "payment-error") {
        const { status, headers, body } = result.response;
        return respond(req, res, status, headers, body ?? {});
      }
      // payment-verified → settle, then serve the protected resource
      const settle = await server.processSettlement(
        result.paymentPayload,
        result.paymentRequirements,
        result.declaredExtensions
      );
      if (!settle.success) {
        const { status, headers, body } = settle.response;
        return respond(req, res, status, headers, body ?? {});
      }
      return respond(req, res, 200, settle.headers, {
        premium: true,
        message: "x402 payment settled on Hedera testnet",
        transaction: settle.transaction,
        transactionId: settle.transactionId ?? null, // O4: observe which key exists
        payer: settle.payer,
        network: settle.network,
      });
    } catch (error) {
      console.error(error);
      return respond(req, res, 500, {}, { error: String(error) });
    }
  })
  .listen(PORT, () => {
    console.log(`spike resource server :${PORT}, payTo ${PAY_TO}, facilitator ${FACILITATOR_URL}`);
  });
