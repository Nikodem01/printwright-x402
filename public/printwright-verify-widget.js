(function (root) {
  "use strict";

  const MIRRORS = Object.freeze({
    testnet: "https://testnet.mirrornode.hedera.com",
    mainnet: "https://mainnet-public.mirrornode.hedera.com",
  });
  const CERTIFICATE_KEYS = Object.freeze([
    "v", "cert_id", "model_id", "model_hash", "designer", "license_type",
    "unit_serial", "buyer_hint", "payment_tx", "issued_at", "terms_hash",
  ]);
  const MAX_PAGES = 25;
  const MAX_RESPONSE_BYTES = 1_048_576;

  class VerificationError extends Error {
    constructor(message, code = "verification_failed") {
      super(message);
      this.name = "VerificationError";
      this.code = code;
    }
  }

  async function verifyCertificate({ certId, topicId, network = "testnet", fetchImpl = root.fetch, timeoutMs = 10_000 }) {
    requirePattern(certId, /^pw-[0-9]{6,}$/, "certId must match pw-NNNNNN");
    requirePattern(topicId, /^\d+\.\d+\.\d+$/, "topicId must be a Hedera entity id");
    if (!Object.hasOwn(MIRRORS, network)) {
      throw new VerificationError("network must be testnet or mainnet", "invalid_input");
    }
    if (typeof fetchImpl !== "function") {
      throw new VerificationError("a fetch implementation is required", "invalid_input");
    }

    const mirror = new URL(MIRRORS[network]);
    let pageUrl = new URL(`/api/v1/topics/${topicId}/messages?limit=100&order=desc`, mirror);
    const visited = new Set();

    for (let page = 0; page < MAX_PAGES && pageUrl; page += 1) {
      if (visited.has(pageUrl.href)) {
        throw new VerificationError("mirror pagination repeated a page", "invalid_mirror_response");
      }
      visited.add(pageUrl.href);
      const body = await fetchJson(pageUrl, fetchImpl, timeoutMs);
      if (!Array.isArray(body.messages)) {
        throw new VerificationError("mirror response has no messages array", "invalid_mirror_response");
      }

      for (const envelope of body.messages) {
        const decoded = decodePayload(envelope && envelope.message);
        if (decoded && decoded.cert_id === certId) return verifiedResult(envelope, certId, topicId, network);
      }
      pageUrl = nextPage(body.links && body.links.next, mirror, topicId);
    }

    if (pageUrl) throw new VerificationError("mirror pagination limit reached", "invalid_mirror_response");
    throw new VerificationError(`${certId} was not found on topic ${topicId}`, "certificate_not_found");
  }

  function validateCertificate(certificate) {
    const errors = [];
    if (!plainObject(certificate)) return ["certificate must be a JSON object"];

    const missing = CERTIFICATE_KEYS.filter((key) => !Object.hasOwn(certificate, key));
    const extra = Object.keys(certificate).filter((key) => !CERTIFICATE_KEYS.includes(key));
    if (missing.length) errors.push(`missing fields: ${missing.join(", ")}`);
    if (extra.length) errors.push(`unknown fields: ${extra.join(", ")}`);
    if (certificate.v !== 1) errors.push("v must equal 1");
    if (!/^pw-[0-9]{6,}$/.test(certificate.cert_id)) errors.push("cert_id must match pw-NNNNNN");
    if (!positiveInteger(certificate.model_id)) errors.push("model_id must be a positive integer");
    if (!sha256(certificate.model_hash)) errors.push("model_hash must be sha256:<64 lowercase hex>");
    if (!entityId(certificate.designer)) errors.push("designer must be a Hedera account id");
    if (!["personal", "commercial_unit"].includes(certificate.license_type)) {
      errors.push("license_type must be personal or commercial_unit");
    }
    if (!positiveInteger(certificate.unit_serial)) errors.push("unit_serial must be a positive integer");
    if (!(certificate.buyer_hint === "bearer" || entityId(certificate.buyer_hint))) {
      errors.push("buyer_hint must be bearer or a Hedera account id");
    }
    if (!/^\d+\.\d+\.\d+@\d+\.\d{1,9}$/.test(certificate.payment_tx)) {
      errors.push("payment_tx must be a Hedera transaction id");
    }
    if (typeof certificate.issued_at !== "string" ||
        !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/.test(certificate.issued_at) ||
        Number.isNaN(Date.parse(certificate.issued_at))) {
      errors.push("issued_at must be an RFC 3339 UTC timestamp");
    }
    if (!sha256(certificate.terms_hash)) errors.push("terms_hash must be sha256:<64 lowercase hex>");
    return errors;
  }

  function verifiedResult(envelope, certId, topicId, network) {
    if (!plainObject(envelope) || envelope.topic_id !== topicId || !positiveInteger(envelope.sequence_number) ||
        !/^\d+\.\d{9}$/.test(envelope.consensus_timestamp)) {
      throw new VerificationError("mirror message location is invalid", "invalid_mirror_response");
    }
    const certificate = decodePayload(envelope.message);
    const errors = validateCertificate(certificate);
    if (errors.length) throw new VerificationError(errors.join("; "), "invalid_certificate");
    if (certificate.cert_id !== certId) {
      throw new VerificationError("certificate id does not match", "location_mismatch");
    }
    return Object.freeze({
      verified: true,
      standard: "PWC-1",
      network,
      certificate: Object.freeze(certificate),
      topic_id: topicId,
      sequence_number: envelope.sequence_number,
      consensus_timestamp: envelope.consensus_timestamp,
      mirror_url: `${MIRRORS[network]}/api/v1/topics/${topicId}/messages/${envelope.sequence_number}`,
    });
  }

  async function fetchJson(url, fetchImpl, timeoutMs) {
    const controller = new AbortController();
    const timer = root.setTimeout(() => controller.abort(), timeoutMs);
    let response;
    try {
      response = await fetchImpl(url.href, {
        headers: { accept: "application/json" },
        redirect: "error",
        signal: controller.signal,
      });
    } catch (error) {
      throw new VerificationError(`mirror request failed: ${error.message}`, "mirror_unavailable");
    } finally {
      root.clearTimeout(timer);
    }
    if (!response.ok) throw new VerificationError(`mirror returned HTTP ${response.status}`, "mirror_unavailable");
    const text = await response.text();
    if (text.length > MAX_RESPONSE_BYTES) {
      throw new VerificationError("mirror response is too large", "invalid_mirror_response");
    }
    try {
      return JSON.parse(text);
    } catch (_error) {
      throw new VerificationError("mirror returned invalid JSON", "invalid_mirror_response");
    }
  }

  function decodePayload(encoded) {
    if (typeof encoded !== "string" ||
        !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(encoded)) return null;
    try {
      const binary = root.atob(encoded);
      if (root.btoa(binary) !== encoded) return null;
      const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
      const value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
      return plainObject(value) ? value : null;
    } catch (_error) {
      return null;
    }
  }

  function nextPage(next, mirror, topicId) {
    if (!next) return null;
    const url = new URL(next, mirror);
    const topicPath = `/api/v1/topics/${topicId}/messages`;
    if (url.origin !== mirror.origin || url.pathname !== topicPath) {
      throw new VerificationError("mirror pagination left the requested topic", "invalid_mirror_response");
    }
    return url;
  }

  function requirePattern(value, pattern, message) {
    if (typeof value !== "string" || !pattern.test(value)) throw new VerificationError(message, "invalid_input");
  }

  function plainObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
  }

  function positiveInteger(value) {
    return Number.isSafeInteger(value) && value > 0;
  }

  function entityId(value) {
    return typeof value === "string" && /^\d+\.\d+\.\d+$/.test(value);
  }

  function sha256(value) {
    return typeof value === "string" && /^sha256:[0-9a-f]{64}$/.test(value);
  }

  root.PrintwrightVerify = Object.freeze({ VerificationError, validateCertificate, verifyCertificate });

  if (root.customElements && root.HTMLElement && !root.customElements.get("printwright-verify")) {
    class PrintwrightVerifyElement extends root.HTMLElement {
      static get observedAttributes() { return ["cert-id", "topic-id", "network"]; }

      constructor() {
        super();
        this.attachShadow({ mode: "open" });
        this.requestNumber = 0;
      }

      connectedCallback() { this.verify(); }
      attributeChangedCallback() { if (this.isConnected) this.verify(); }

      async verify() {
        const requestNumber = ++this.requestNumber;
        this.render("checking", "Checking Hedera mirror…");
        try {
          const result = await verifyCertificate({
            certId: this.getAttribute("cert-id") || "",
            topicId: this.getAttribute("topic-id") || "",
            network: this.getAttribute("network") || "testnet",
          });
          if (requestNumber === this.requestNumber) this.renderVerified(result);
        } catch (error) {
          if (requestNumber === this.requestNumber) this.render("failed", error.message);
        }
      }

      render(state, message) {
        this.dataset.state = state;
        this.shadowRoot.replaceChildren(styles(), card(
          state === "checking" ? "◌" : "×",
          state === "checking" ? "Checking certificate" : "Not verified",
          message,
          state
        ));
      }

      renderVerified(result) {
        this.dataset.state = "verified";
        const content = card(
          "✓",
          `${result.certificate.cert_id} verified`,
          `PWC-1 · ${result.certificate.license_type.replace("_", " ")} · unit ${result.certificate.unit_serial}`,
          "verified"
        );
        const link = document.createElement("a");
        link.href = result.mirror_url;
        link.target = "_blank";
        link.rel = "noopener noreferrer";
        link.textContent = `Hedera ${result.topic_id} · message ${result.sequence_number}`;
        content.append(link);
        this.shadowRoot.replaceChildren(styles(), content);
      }
    }

    root.customElements.define("printwright-verify", PrintwrightVerifyElement);
  }

  function card(mark, title, detail, state) {
    const container = document.createElement("section");
    container.className = `card ${state}`;
    container.setAttribute("role", "status");
    const badge = document.createElement("span");
    badge.className = "mark";
    badge.textContent = mark;
    const copy = document.createElement("span");
    const heading = document.createElement("strong");
    heading.textContent = title;
    const description = document.createElement("small");
    description.textContent = detail;
    copy.append(heading, description);
    container.append(badge, copy);
    return container;
  }

  function styles() {
    const style = document.createElement("style");
    style.textContent = `
      :host { display: block; max-width: 31rem; color: #20201d; font: 14px/1.4 ui-sans-serif, system-ui, sans-serif; }
      .card { align-items: center; background: #fff; border: 1px solid #bbb; border-radius: 10px; display: grid; gap: 10px; grid-template-columns: auto 1fr; padding: 12px 14px; }
      .card.verified { border-color: #16734a; }
      .card.failed { border-color: #a33a2b; }
      .mark { align-items: center; background: #eee; border-radius: 50%; display: inline-flex; font-size: 16px; font-weight: 700; height: 30px; justify-content: center; width: 30px; }
      .verified .mark { background: #d9f5e7; color: #0c653d; }
      .failed .mark { background: #fbe1dc; color: #8b281d; }
      strong, small, a { display: block; overflow-wrap: anywhere; }
      small { color: #666; margin-top: 1px; }
      a { color: #11624a; font-size: 12px; grid-column: 2; margin-top: 4px; }
    `;
    return style;
  }
})(globalThis);
