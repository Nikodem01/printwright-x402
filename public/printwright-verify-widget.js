(function (root) {
  "use strict";

  // Browser twin of the standalone verifier/ CLI. A Printwright license lives
  // off-chain: Hedera carries only an opaque commitment, and the holder proves
  // their certificate by disclosing a proof bundle. This widget recomputes the
  // commitment locally — SHA-256( DOMAIN || nonce || JCS(certificate) ) — and
  // confirms it equals the envelope anchored on a public Hedera mirror node.
  //
  // It never calls Printwright to reach a verdict. The bundle may come from
  // anywhere (an attribute URL, or inline JSON), but the mirror is always one
  // of the well-known Hedera hosts below and its URL is derived from the
  // bundle's topic id and sequence number — a bundle that could name its own
  // "mirror" would be a bundle that verifies itself.

  const MIRRORS = Object.freeze({
    testnet: "https://testnet.mirrornode.hedera.com",
    mainnet: "https://mainnet-public.mirrornode.hedera.com",
  });
  const ALGORITHM = "sha256-jcs-v1";
  const ENVELOPE_TYPE = "printwright-license-commitment";
  const DOMAIN = "printwright:license-certificate:v1\u0000";
  const CERTIFICATE_KEYS = Object.freeze([
    "v", "cert_id", "model_id", "model_hash", "designer", "license_type",
    "unit_serial", "buyer_hint", "payment_tx", "issued_at", "terms_hash",
  ]);
  const MAX_RESPONSE_BYTES = 1_048_576;

  class VerificationError extends Error {
    constructor(message, code = "verification_failed") {
      super(message);
      this.name = "VerificationError";
      this.code = code;
    }
  }

  // RFC 8785 JSON Canonicalization Scheme. Byte-identical to the Ruby side that
  // anchors the commitment and to verifier/index.js; a shared test vector pins
  // all three together.
  function canonicalize(value) {
    if (value === null || typeof value !== "object" || value.toJSON != null) {
      return JSON.stringify(value);
    }
    if (Array.isArray(value)) return `[${value.map(canonicalize).join(",")}]`;
    const members = Object.keys(value).sort().map(
      (key) => `${JSON.stringify(key)}:${canonicalize(value[key])}`,
    );
    return `{${members.join(",")}}`;
  }

  async function computeCommitment(certificate, nonceHex, subtle) {
    if (typeof nonceHex !== "string" || !/^(?:[0-9a-f]{2})+$/i.test(nonceHex)) {
      throw new VerificationError("blinding_nonce must be hex", "invalid_input");
    }
    const encoder = new TextEncoder();
    const domain = encoder.encode(DOMAIN);
    const nonce = Uint8Array.from(nonceHex.match(/../g), (byte) => parseInt(byte, 16));
    const canonical = encoder.encode(canonicalize(certificate));
    const preimage = new Uint8Array(domain.length + nonce.length + canonical.length);
    preimage.set(domain, 0);
    preimage.set(nonce, domain.length);
    preimage.set(canonical, domain.length + nonce.length);
    const digest = await subtle.digest("SHA-256", preimage);
    return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
  }

  async function sha256Prefixed(text, subtle) {
    const digest = await subtle.digest("SHA-256", new TextEncoder().encode(String(text)));
    const hex = Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
    return `sha256:${hex}`;
  }

  function validateCertificate(certificate) {
    const errors = [];
    if (!plainObject(certificate)) return [ "certificate must be a JSON object" ];

    const missing = CERTIFICATE_KEYS.filter((key) => !Object.hasOwn(certificate, key));
    const extra = Object.keys(certificate).filter((key) => !CERTIFICATE_KEYS.includes(key));
    if (missing.length) errors.push(`missing fields: ${missing.join(", ")}`);
    if (extra.length) errors.push(`unknown fields: ${extra.join(", ")}`);
    if (certificate.v !== 1) errors.push("v must equal 1");
    if (!/^(sandbox-)?pw-[0-9a-f]{16,}$/.test(String(certificate.cert_id))) {
      errors.push("cert_id must be an unguessable pw- token");
    }
    if (!positiveInteger(certificate.model_id)) errors.push("model_id must be a positive integer");
    if (!sha256(certificate.model_hash)) errors.push("model_hash must be sha256:<64 lowercase hex>");
    // A stable studio id — never a wallet: payout accounts stay private.
    if (!positiveInteger(certificate.designer)) errors.push("designer must be a positive integer studio id");
    if (![ "personal", "commercial_unit" ].includes(certificate.license_type)) {
      errors.push("license_type must be personal or commercial_unit");
    }
    if (!positiveInteger(certificate.unit_serial)) errors.push("unit_serial must be a positive integer");
    if (!/^(bearer|sandbox-buyer|\d+\.\d+\.\d+)$/.test(String(certificate.buyer_hint))) {
      errors.push("buyer_hint must be bearer or a Hedera account id");
    }
    if (!/^(sandbox-tx-[0-9a-f]+|\d+\.\d+\.\d+@\d+\.\d{1,9})$/.test(String(certificate.payment_tx))) {
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

  // Verify a proof bundle. `expectedTopicId` lets an embedder pin the topic it
  // trusts, so a bundle anchored to some other topic cannot pass as licensed.
  async function verifyBundle(bundle, {
    expectedTopicId = null,
    network = null,
    fetchImpl = root.fetch,
    subtle = root.crypto && root.crypto.subtle,
    timeoutMs = 10_000,
  } = {}) {
    if (!plainObject(bundle)) throw new VerificationError("proof bundle must be a JSON object", "invalid_input");
    if (bundle.algorithm !== ALGORITHM) {
      throw new VerificationError(`unsupported algorithm: ${bundle.algorithm}`, "invalid_input");
    }
    if (!subtle) {
      throw new VerificationError("Web Crypto is unavailable — serve this page over HTTPS", "crypto_unavailable");
    }
    const certificate = bundle.certificate;
    if (!plainObject(certificate)) {
      throw new VerificationError("bundle must carry a certificate", "invalid_input");
    }

    const checks = {};
    const commitment = await computeCommitment(certificate, bundle.blinding_nonce, subtle);
    checks.bundle_integrity = commitment === bundle.commitment ? "verified" : "failed";

    const certificateErrors = validateCertificate(certificate);
    checks.certificate_schema = certificateErrors.length === 0 ? "verified" : "failed";

    const terms = plainObject(bundle.terms) ? bundle.terms : null;
    if (terms && typeof terms.text === "string") {
      const hash = await sha256Prefixed(terms.text, subtle);
      checks.terms_integrity =
        hash === terms.hash && terms.hash === certificate.terms_hash ? "verified" : "failed";
    } else {
      checks.terms_integrity = "unchecked";
    }

    const hedera = plainObject(bundle.hedera) ? bundle.hedera : {};
    const topicId = String(hedera.topic_id || "");
    let consensusTimestamp = null;
    let mirrorUrl = null;
    if (hedera.status === "minting" || !hedera.topic_id) {
      checks.hedera_anchoring = "pending";
    } else if (expectedTopicId && topicId !== expectedTopicId) {
      checks.hedera_anchoring = "failed";
    } else {
      mirrorUrl = mirrorMessageUrl(hedera, network);
      const message = await fetchJson(mirrorUrl, fetchImpl, timeoutMs);
      const onchain = decodePayload(message && message.message);
      if (!onchain || onchain.type !== ENVELOPE_TYPE) {
        checks.hedera_anchoring = "failed";
      } else {
        checks.hedera_anchoring = onchain.commitment === commitment ? "verified" : "failed";
        consensusTimestamp = (message && message.consensus_timestamp) || null;
      }
    }

    // Hedera timestamps and freezes the committed bytes. It cannot vouch for
    // the issuer's authority to license the model, or for any physical print.
    checks.issuer_assertions = "not_independently_proven";

    const verified = checks.bundle_integrity === "verified" &&
      checks.certificate_schema === "verified" &&
      checks.hedera_anchoring === "verified" &&
      checks.terms_integrity !== "failed";

    return Object.freeze({
      verified,
      cert_id: certificate.cert_id,
      commitment,
      checks: Object.freeze(checks),
      certificate: Object.freeze(certificate),
      certificate_errors: Object.freeze(certificateErrors),
      topic_id: hedera.topic_id || null,
      sequence_number: hedera.sequence_number || null,
      consensus_timestamp: consensusTimestamp,
      mirror_url: mirrorUrl,
    });
  }

  function mirrorMessageUrl(hedera, network) {
    const chosen = network || hedera.network || "testnet";
    if (!Object.hasOwn(MIRRORS, chosen)) {
      throw new VerificationError(`network must be one of: ${Object.keys(MIRRORS).join(", ")}`, "invalid_input");
    }
    if (!/^\d+\.\d+\.\d+$/.test(String(hedera.topic_id))) {
      throw new VerificationError("topic_id must be a Hedera entity id", "invalid_input");
    }
    if (!positiveInteger(hedera.sequence_number)) {
      throw new VerificationError("sequence_number must be a positive integer", "invalid_input");
    }
    return `${MIRRORS[chosen]}/api/v1/topics/${hedera.topic_id}/messages/${hedera.sequence_number}`;
  }

  async function fetchJson(url, fetchImpl, timeoutMs) {
    if (typeof fetchImpl !== "function") {
      throw new VerificationError("a fetch implementation is required", "invalid_input");
    }
    const controller = new AbortController();
    const timer = root.setTimeout(() => controller.abort(), timeoutMs);
    let response;
    try {
      response = await fetchImpl(url, {
        headers: { accept: "application/json" },
        redirect: "error",
        signal: controller.signal,
      });
    } catch (error) {
      throw new VerificationError(`request failed: ${error.message}`, "mirror_unavailable");
    } finally {
      root.clearTimeout(timer);
    }
    if (!response.ok) throw new VerificationError(`request returned HTTP ${response.status}`, "mirror_unavailable");
    const text = await response.text();
    if (text.length > MAX_RESPONSE_BYTES) {
      throw new VerificationError("response is too large", "invalid_response");
    }
    try {
      return JSON.parse(text);
    } catch (_error) {
      throw new VerificationError("response is not valid JSON", "invalid_response");
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

  function plainObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
  }

  function positiveInteger(value) {
    return Number.isSafeInteger(value) && value > 0;
  }

  function sha256(value) {
    return typeof value === "string" && /^sha256:[0-9a-f]{64}$/.test(value);
  }

  root.PrintwrightVerify = Object.freeze({
    VerificationError, canonicalize, computeCommitment, validateCertificate, verifyBundle,
  });

  if (root.customElements && root.HTMLElement && !root.customElements.get("printwright-verify")) {
    class PrintwrightVerifyElement extends root.HTMLElement {
      static get observedAttributes() { return [ "bundle-url", "topic-id", "network" ]; }

      constructor() {
        super();
        this.attachShadow({ mode: "open" });
        this.requestNumber = 0;
      }

      connectedCallback() { this.verify(); }
      attributeChangedCallback() { if (this.isConnected) this.verify(); }

      async verify() {
        const requestNumber = ++this.requestNumber;
        this.render("Checking this license against Hedera…", "pending");
        try {
          const bundle = await this.loadBundle();
          const result = await verifyBundle(bundle, {
            expectedTopicId: this.getAttribute("topic-id"),
            network: this.getAttribute("network"),
          });
          if (requestNumber !== this.requestNumber) return;
          this.render(this.summary(result), result.verified ? "verified" : "failed", result);
          this.dispatchEvent(new CustomEvent("printwright:verified", { detail: result }));
        } catch (error) {
          if (requestNumber !== this.requestNumber) return;
          this.render(error.message, "failed");
          this.dispatchEvent(new CustomEvent("printwright:failed", { detail: error }));
        }
      }

      // The bundle is the holder's disclosure: either fetched from a URL they
      // publish, or embedded directly in the page as JSON.
      async loadBundle() {
        const url = this.getAttribute("bundle-url");
        if (url) return fetchJson(url, root.fetch, 10_000);
        const inline = this.querySelector('script[type="application/json"]');
        if (inline) {
          try {
            return JSON.parse(inline.textContent);
          } catch (_error) {
            throw new VerificationError("inline proof bundle is not valid JSON", "invalid_input");
          }
        }
        throw new VerificationError(
          "add a bundle-url attribute or an inline <script type=\"application/json\"> proof bundle",
          "invalid_input",
        );
      }

      summary(result) {
        if (result.verified) {
          return `Licensed unit #${result.certificate.unit_serial} · certificate ${result.cert_id}`;
        }
        const failed = Object.keys(result.checks).filter((name) => result.checks[name] === "failed");
        if (failed.length) return `Check failed: ${failed.join(", ")}`;
        return result.checks.hedera_anchoring === "pending"
          ? "Not anchored on Hedera yet — re-check shortly"
          : "This certificate could not be verified";
      }

      render(message, state, result) {
        const palette = { verified: "#1c7c4a", failed: "#a8261f", pending: "#6b6b63" };
        const detail = result && result.consensus_timestamp
          ? `Committed to topic ${result.topic_id} at consensus ${result.consensus_timestamp}. ` +
            "Hedera proves these bytes existed no later than that timestamp — not the truth of what they assert."
          : "";
        this.shadowRoot.replaceChildren();
        const wrapper = document.createElement("div");
        wrapper.setAttribute("part", "container");
        wrapper.setAttribute("role", "status");
        wrapper.style.cssText =
          "font:14px/1.45 system-ui,sans-serif;border:1px solid " + palette[state] +
          ";border-radius:8px;padding:.75rem .9rem;color:" + palette[state] + ";max-width:36rem";
        const line = document.createElement("strong");
        line.textContent = (state === "verified" ? "✓ " : state === "failed" ? "✗ " : "… ") + message;
        wrapper.append(line);
        if (detail) {
          const small = document.createElement("small");
          small.style.cssText = "display:block;margin-top:.4rem;color:#4a4a44";
          small.textContent = detail;
          wrapper.append(small);
        }
        if (result && result.mirror_url) {
          const link = document.createElement("a");
          link.href = result.mirror_url;
          link.rel = "noopener";
          link.textContent = "See the message on the Hedera mirror";
          link.style.cssText = "display:block;margin-top:.4rem;color:inherit";
          wrapper.append(link);
        }
        this.shadowRoot.append(wrapper);
      }
    }

    root.customElements.define("printwright-verify", PrintwrightVerifyElement);
  }
})(typeof globalThis === "undefined" ? this : globalThis);
