// HTTP layer, kept separate from the SDK so tests can inject a fake `hedera`.
import http from "node:http";

const MAX_MESSAGE_BYTES = 1024; // keep provenance records in one HCS message

export function createApp({
  hedera, token, topicId, heartbeatTopicId = () => undefined,
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
      "/create-topic", "/create-heartbeat-topic", "/submit-cert", "/submit-version",
      "/submit-heartbeat", "/payout", "/create-collection", "/mint-airdrop",
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

      if (req.url === "/create-heartbeat-topic") {
        return send(200, await hedera.createHeartbeatTopic());
      }

      if (req.url === "/submit-heartbeat") {
        if (!validHeartbeat(body.heartbeat, hedera.network)) {
          return send(400, { error: "invalid_heartbeat" });
        }
        const target = heartbeatTopicId();
        if (!target) return send(400, { error: "no_heartbeat_topic_configured" });

        const message = JSON.stringify(body.heartbeat);
        if (Buffer.byteLength(message, "utf8") > MAX_MESSAGE_BYTES) {
          return send(422, { error: "heartbeat_too_large", limit: MAX_MESSAGE_BYTES });
        }
        return send(200, await hedera.submitMessage(target, message));
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

  function validHeartbeat(heartbeat, network) {
    if (!heartbeat || typeof heartbeat !== "object" || Array.isArray(heartbeat)) return false;
    const keys = Object.keys(heartbeat).sort();
    const expected = ["network", "observed_at", "schema", "service", "status"];
    if (keys.length !== expected.length || keys.some((key, index) => key !== expected[index])) return false;
    return heartbeat.schema === "pwh-1" &&
      heartbeat.service === "printwright" &&
      heartbeat.status === "alive" &&
      heartbeat.network === `hedera:${network}` &&
      typeof heartbeat.observed_at === "string" &&
      /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(heartbeat.observed_at) &&
      Number.isFinite(Date.parse(heartbeat.observed_at));
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
