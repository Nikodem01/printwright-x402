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

    if (req.method !== "POST" || !["/create-topic", "/submit-cert"].includes(req.url)) {
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

  return http.createServer((req, res) => {
    handle(req, res).catch((error) => {
      console.error(error);
      res.writeHead(500, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "internal" }));
    });
  });
}
