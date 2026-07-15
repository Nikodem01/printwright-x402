// Transparent logging proxy in front of the x402 facilitator.
// The resource server points at this instead of the facilitator directly, so
// every /verify and /settle request/response is captured byte-for-byte in
// wire-log/facilitator.jsonl (these captures become WebMock fixtures later).
import "dotenv/config";
import http from "node:http";
import { wireLog } from "./wirelog.mjs";

const UPSTREAM = process.env.FACILITATOR_URL || "https://api.testnet.blocky402.com";
const PORT = Number(process.env.PROXY_PORT || 4403);

http
  .createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const requestBody = Buffer.concat(chunks).toString("utf8");

    try {
      const upstream = await fetch(UPSTREAM + req.url, {
        method: req.method,
        headers: { "content-type": req.headers["content-type"] || "application/json" },
        body: ["GET", "HEAD"].includes(req.method) ? undefined : requestBody,
      });
      const responseBody = await upstream.text();
      wireLog("facilitator.jsonl", {
        method: req.method,
        path: req.url,
        requestBody: requestBody || null,
        status: upstream.status,
        responseHeaders: Object.fromEntries(upstream.headers),
        responseBody,
      });
      res.writeHead(upstream.status, {
        "content-type": upstream.headers.get("content-type") || "application/json",
      });
      res.end(responseBody);
    } catch (error) {
      wireLog("facilitator.jsonl", { method: req.method, path: req.url, error: String(error) });
      res.writeHead(502, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "facilitator_proxy_error", detail: String(error) }));
    }
  })
  .listen(PORT, () => console.log(`facilitator proxy :${PORT} → ${UPSTREAM}`));
