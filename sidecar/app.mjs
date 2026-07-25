// HTTP layer, kept separate from the SDK so tests can inject a fake `hedera`.
import http from "node:http";

const MAX_MESSAGE_BYTES = 1024; // keep provenance records in one HCS message

export function createApp({
  hedera, token, topicId,
  captureException = () => undefined,
}) {
  async function handle(req, res) {
    const send = (status, body) => {
      res.writeHead(status, { "content-type": "application/json" });
      res.end(JSON.stringify(body));
    };

    if (req.method === "GET" && req.url === "/healthz") {
      return send(200, { ok: true, network: hedera.network, topicId: topicId() ?? null });
    }

    const routes = [
      "/create-topic", "/submit-cert", "/submit-version",
      "/payout", "/verify-payout-proof",
    ];
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

      if (req.url === "/verify-payout-proof") {
        if (typeof body.accountId !== "string" || !/^0\.0\.\d+$/.test(body.accountId)) {
          return send(400, { error: "invalid_account_id" });
        }
        if (typeof body.message !== "string" || body.message.length === 0 ||
            Buffer.byteLength(body.message, "utf8") > 1024) {
          return send(400, { error: "invalid_message" });
        }
        if (typeof body.signatureMap !== "string" || body.signatureMap.length === 0 ||
            body.signatureMap.length > 4096 || !/^[A-Za-z0-9+/]+={0,2}$/.test(body.signatureMap)) {
          return send(400, { error: "invalid_signature_map" });
        }
        const verified = await hedera.verifyPayoutProof({
          accountId: body.accountId,
          message: body.message,
          signatureMap: body.signatureMap,
        });
        return send(200, { verified });
      }

      // Certificate and version events share the configured provenance topic,
      // but remain distinct schemas so one can never masquerade as the other.
      const isVersion = req.url === "/submit-version";
      if (isVersion && (!body.version || typeof body.version !== "object" || body.version.schema !== "pwv-1")) {
        return send(400, { error: "invalid_version_event" });
      }
      if (!isVersion && (!body.cert || typeof body.cert !== "object")) {
        return send(400, { error: "missing_cert" });
      }
      const target = body.topicId || topicId();
      if (!target) {
        return send(400, { error: "no_topic_configured" });
      }
      const message = JSON.stringify(isVersion ? body.version : body.cert); // compact, no whitespace
      if (Buffer.byteLength(message, "utf8") > MAX_MESSAGE_BYTES) {
        return send(422, {
          error: isVersion ? "version_event_too_large" : "cert_too_large",
          limit: MAX_MESSAGE_BYTES,
        });
      }
      const result = await hedera.submitMessage(target, message);
      return send(200, result);
    } catch (error) {
      captureException(error, { tags: { component: "hedera-sidecar", boundary: "request" } });
      console.error(`sidecar request failed (${error?.name || "Error"})`);
      return send(502, { error: "hedera_error" });
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
      captureException(error, { tags: { component: "hedera-sidecar", boundary: "server" } });
      console.error(`sidecar server failed (${error?.name || "Error"})`);
      res.writeHead(500, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "internal" }));
    });
  });
}
