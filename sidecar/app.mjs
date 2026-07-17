// HTTP layer, kept separate from the SDK so tests can inject a fake `hedera`.
import http from "node:http";

const MAX_CERT_BYTES = 1024; // HCS single-chunk message limit — certs must fit

export function createApp({ hedera, token, topicId }) {
  async function handle(req, res) {
    const send = (status, body) => {
      res.writeHead(status, { "content-type": "application/json" });
      res.end(JSON.stringify(body));
    };

    if (req.method === "GET" && req.url === "/healthz") {
      return send(200, { ok: true, network: hedera.network, topicId: topicId() ?? null });
    }

    const routes = ["/create-topic", "/submit-cert", "/payout", "/create-collection", "/mint-airdrop"];
    if (req.method !== "POST" || !routes.includes(req.url)) {
      return send(404, { error: "not_found" });
    }
    if (req.headers.authorization !== `Bearer ${token}`) {
      return send(401, { error: "unauthorized" });
    }

    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    let body = {};
    if (chunks.length > 0) {
      try {
        body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      } catch {
        return send(400, { error: "invalid_json" });
      }
    }

    try {
      if (req.url === "/create-topic") {
        const memo = body.memo || "printwright license certificates v1";
        return send(200, await hedera.createTopic(memo));
      }

      if (req.url === "/create-collection") {
        if (typeof body.name !== "string" || body.name.length === 0 || body.name.length > 100) {
          return send(400, { error: "invalid_name" });
        }
        if (typeof body.royaltyCollector !== "string" || !/^0\.0\.\d+$/.test(body.royaltyCollector)) {
          return send(400, { error: "invalid_royalty_collector" });
        }
        const pct = Number(body.royaltyPercent);
        if (!Number.isInteger(pct) || pct < 0 || pct > 50) {
          return send(400, { error: "invalid_royalty_percent" });
        }
        return send(200, await hedera.createLicenseCollection({
          name: body.name,
          symbol: (body.symbol || "PWL").slice(0, 10),
          royaltyCollector: body.royaltyCollector,
          royaltyPercent: pct,
        }));
      }

      if (req.url === "/mint-airdrop") {
        if (typeof body.tokenId !== "string" || !/^0\.0\.\d+$/.test(body.tokenId)) {
          return send(400, { error: "invalid_token_id" });
        }
        if (typeof body.recipient !== "string" || !/^0\.0\.\d+$/.test(body.recipient)) {
          return send(400, { error: "invalid_recipient" });
        }
        if (typeof body.metadata !== "string" || body.metadata.length === 0 || Buffer.byteLength(body.metadata) > 100) {
          return send(400, { error: "invalid_metadata" }); // HTS metadata cap
        }
        return send(200, await hedera.mintAndAirdrop({
          tokenId: body.tokenId,
          metadata: body.metadata,
          recipient: body.recipient,
        }));
      }

      if (req.url === "/payout") {
        if (!hedera.treasuryConfigured) {
          return send(503, { error: "treasury_not_configured" });
        }
        const bad = validatePayout(body);
        if (bad) return send(400, { error: bad });
        return send(200, await hedera.payout({
          tokenId: body.tokenId,
          transfers: body.transfers,
          memo: body.memo,
        }));
      }

      // /submit-cert
      if (!body.cert || typeof body.cert !== "object") {
        return send(400, { error: "missing_cert" });
      }
      const target = body.topicId || topicId();
      if (!target) {
        return send(400, { error: "no_topic_configured" });
      }
      const message = JSON.stringify(body.cert); // compact, no whitespace
      if (Buffer.byteLength(message, "utf8") > MAX_CERT_BYTES) {
        return send(422, { error: "cert_too_large", limit: MAX_CERT_BYTES });
      }
      const result = await hedera.submitMessage(target, message);
      return send(200, result);
    } catch (error) {
      console.error(error);
      return send(502, { error: "hedera_error", detail: String(error) });
    }
  }

  function validatePayout(body) {
    if (typeof body.tokenId !== "string" || !/^0\.0\.\d+$/.test(body.tokenId)) return "invalid_token_id";
    if (!Array.isArray(body.transfers) || body.transfers.length === 0) return "missing_transfers";
    for (const t of body.transfers) {
      if (typeof t.accountId !== "string" || !/^0\.0\.\d+$/.test(t.accountId)) return "invalid_transfer_account";
      if (typeof t.amount !== "string" || !/^[1-9]\d*$/.test(t.amount)) return "invalid_transfer_amount";
    }
    return null;
  }

  return http.createServer((req, res) => {
    handle(req, res).catch((error) => {
      console.error(error);
      res.writeHead(500, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "internal" }));
    });
  });
}
