#!/usr/bin/env node
// Demo wallet signer: a separate local process holding ONLY the demo buyer's
// key — architecturally a wallet (the marketplace never sees the key). The
// browser checkout asks it to sign an x402 PaymentRequired quote; swapping
// this call for HashPack's hashconnect.signTransaction is the planned upgrade.
import "dotenv/config";
import http from "node:http";
import { x402Client, x402HTTPClient } from "@x402/core/client";
import { createClientHederaSigner, PrivateKey } from "@x402/hedera";
import { ExactHederaScheme } from "@x402/hedera/exact/client";

const PORT = Number(process.env.DEMO_WALLET_PORT || 4022);
const ACCOUNT_ID = process.env.BUYER_ACCOUNT_ID || process.env.HEDERA_ACCOUNT_ID;
const PRIVATE_KEY = process.env.BUYER_PRIVATE_KEY || process.env.HEDERA_PRIVATE_KEY;
if (!ACCOUNT_ID || !PRIVATE_KEY) throw new Error("BUYER_ACCOUNT_ID / BUYER_PRIVATE_KEY required");

const signer = createClientHederaSigner(ACCOUNT_ID, PrivateKey.fromStringECDSA(PRIVATE_KEY), {
  network: "hedera:testnet",
});
const httpClient = new x402HTTPClient(new x402Client().register("hedera:*", new ExactHederaScheme(signer)));

const CORS = {
  "access-control-allow-origin": "http://localhost:3000",
  "access-control-allow-methods": "POST, GET, OPTIONS",
  "access-control-allow-headers": "content-type",
};

http
  .createServer(async (req, res) => {
    const send = (status, body) =>
      res.writeHead(status, { "content-type": "application/json", ...CORS }).end(JSON.stringify(body));

    if (req.method === "OPTIONS") return res.writeHead(204, CORS).end();
    if (req.method === "GET" && req.url === "/healthz") {
      return send(200, { ok: true, account: ACCOUNT_ID });
    }
    if (req.method !== "POST" || req.url !== "/sign") return send(404, { error: "not_found" });

    try {
      const chunks = [];
      for await (const c of req) chunks.push(c);
      const { paymentRequired, asset } = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      const accepts = asset
        ? paymentRequired.accepts.filter((a) => a.asset === asset)
        : paymentRequired.accepts;
      if (!accepts.length) return send(422, { error: "no acceptable payment option" });

      const payload = await httpClient.createPaymentPayload({ ...paymentRequired, accepts: [accepts[0]] });
      const headers = httpClient.encodePaymentSignatureHeader(payload);
      console.log(`signed: ${accepts[0].amount} of ${accepts[0].asset} -> ${accepts[0].payTo}`);
      send(200, { headers, accept: accepts[0], payer: ACCOUNT_ID });
    } catch (error) {
      console.error(error);
      send(500, { error: String(error.message || error) });
    }
  })
  .listen(PORT, "127.0.0.1", () =>
    console.log(`demo wallet (account ${ACCOUNT_ID}) signing on 127.0.0.1:${PORT}`));
