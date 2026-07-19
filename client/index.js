import { x402Client, x402HTTPClient } from "@x402/core/client";
import { createClientHederaSigner, PrivateKey } from "@x402/hedera";
import { ExactHederaScheme } from "@x402/hedera/exact/client";
import { Client as HederaClient, TokenAssociateTransaction } from "@hiero-ledger/sdk";

const USDC_IDS = { testnet: "0.0.429274", mainnet: "0.0.456858" };
const ASSET_IDS = { hbar: "0.0.0" };

export class PrintwrightError extends Error {
  constructor(message, { status, body } = {}) {
    super(message);
    this.name = "PrintwrightError";
    this.status = status;
    this.body = body;
  }
}

export class PrintwrightClient {
  constructor({
    baseUrl = "http://localhost:3000",
    accountId,
    privateKey,
    network = "testnet",
    fetch: fetchImplementation = globalThis.fetch,
    autoAssociate = true,
  } = {}) {
    if (![ "testnet", "mainnet" ].includes(network)) {
      throw new TypeError("network must be testnet or mainnet");
    }
    if (typeof fetchImplementation !== "function") {
      throw new TypeError("a fetch implementation is required");
    }

    this.baseUrl = new URL(baseUrl);
    this.baseUrl.pathname = this.baseUrl.pathname.replace(/\/$/, "") + "/";
    this.accountId = accountId;
    this.privateKey = privateKey;
    this.network = network;
    this.fetch = fetchImplementation;
    this.autoAssociate = autoAssociate;
    this.quotes = new WeakSet();
  }

  async search({ query, maxPriceCents, material, supports } = {}) {
    if (!query?.trim()) throw new TypeError("query is required");

    const params = new URLSearchParams({ q: query });
    if (maxPriceCents !== undefined) params.set("max_price_cents", String(maxPriceCents));
    if (material) params.set("material", material);
    if (supports !== undefined) params.set("supports", String(supports));
    return this.getJson(this.url(`api/v1/models?${params}`));
  }

  async get(modelId) {
    return this.getJson(this.url(`api/v1/models/${integerId(modelId, "modelId")}`));
  }

  async quote({ modelId, license = "personal", asset } = {}) {
    const id = integerId(modelId, "modelId");
    const resourceUrl = this.url(`api/v1/models/${id}/download?${new URLSearchParams({ license })}`);
    const response = await this.fetch(resourceUrl, { headers: { accept: "application/json" } });
    const paymentRequired = deepFreeze(await jsonBody(response));
    if (response.status !== 402) {
      throw new PrintwrightError(`expected 402 from ${resourceUrl}, got ${response.status}`, {
        status: response.status, body: paymentRequired,
      });
    }

    const accepted = selectAsset(paymentRequired, asset, this.network);
    const quote = Object.freeze({
      modelId: id,
      license,
      resourceUrl: resourceUrl.toString(),
      paymentRequired,
      accepted,
      responseHeaders: Object.freeze(Object.fromEntries(response.headers)),
    });
    this.quotes.add(quote);
    return quote;
  }

  async buy({ modelId, license = "personal", asset, quote } = {}) {
    this.requireSigner();
    const purchaseQuote = quote || await this.quote({ modelId, license, asset });
    this.validateQuote(purchaseQuote);

    if (this.autoAssociate && purchaseQuote.accepted.asset === USDC_IDS[this.network]) {
      await this.ensureUsdcAssociated();
    }

    const key = typeof this.privateKey === "string"
      ? PrivateKey.fromStringECDSA(this.privateKey)
      : this.privateKey;
    const signer = createClientHederaSigner(this.accountId, key, { network: `hedera:${this.network}` });
    const httpClient = new x402HTTPClient(
      new x402Client().register("hedera:*", new ExactHederaScheme(signer))
    );
    const required = httpClient.getPaymentRequiredResponse(
      (name) => purchaseQuote.responseHeaders[name.toLowerCase()] || null,
      purchaseQuote.paymentRequired
    );
    const payload = await httpClient.createPaymentPayload({ ...required, accepts: [ purchaseQuote.accepted ] });
    const headers = httpClient.encodePaymentSignatureHeader(payload);
    const response = await this.fetch(purchaseQuote.resourceUrl, {
      headers: { accept: "application/json", ...headers },
    });
    const body = await jsonBody(response);
    if (!response.ok) {
      throw new PrintwrightError(`payment failed (${response.status})`, { status: response.status, body });
    }
    return body;
  }

  async verify(certId) {
    if (!certId?.trim()) throw new TypeError("certId is required");

    const ours = await this.getJson(this.url(`api/v1/certificates/${encodeURIComponent(certId)}`));
    if (ours.status !== "anchored") return { ...ours, match: null };

    let mirror;
    try {
      mirror = await this.getJson(new URL(ours.hcs.mirror_url));
    } catch (error) {
      if (error instanceof PrintwrightError && error.status === 404) {
        return { ...ours, match: null, note: "HCS message is anchored but still indexing on the mirror node" };
      }
      throw error;
    }
    let onchain;
    try {
      onchain = JSON.parse(Buffer.from(mirror.message, "base64").toString("utf8"));
    } catch {
      throw new PrintwrightError("mirror node returned an invalid certificate message", { body: mirror });
    }
    return {
      ...ours,
      match: canonical(onchain) === canonical(ours.certificate),
      onchain,
      consensus_timestamp: mirror.consensus_timestamp,
    };
  }

  url(path) {
    return new URL(path, this.baseUrl);
  }

  async getJson(url) {
    let response;
    try {
      response = await this.fetch(url, { headers: { accept: "application/json" } });
    } catch (error) {
      throw new PrintwrightError(`GET ${url} failed: ${error.message}`);
    }
    const body = await jsonBody(response);
    if (!response.ok) {
      throw new PrintwrightError(`GET ${url} -> ${response.status}`, { status: response.status, body });
    }
    return body;
  }

  requireSigner() {
    if (!this.accountId || !this.privateKey) {
      throw new PrintwrightError("accountId and privateKey are required to buy");
    }
  }

  validateQuote(quote) {
    if (!quote || !this.quotes.has(quote)) throw new TypeError("quote must come from this client.quote()");
    const expected = this.url(
      `api/v1/models/${integerId(quote.modelId, "quote.modelId")}/download?${new URLSearchParams({ license: quote.license })}`
    );
    if (quote.resourceUrl !== expected.toString()) {
      throw new TypeError("quote belongs to a different Printwright endpoint");
    }
    const offered = quote.paymentRequired.accepts?.some((candidate) =>
      canonical(candidate) === canonical(quote.accepted));
    if (!offered) throw new TypeError("quote selection is not in the server payment requirements");
  }

  async ensureUsdcAssociated() {
    const tokenId = USDC_IDS[this.network];
    const mirrorUrl = new URL(
      `https://${this.network}.mirrornode.hedera.com/api/v1/accounts/${encodeURIComponent(this.accountId)}/tokens`
    );
    mirrorUrl.searchParams.set("token.id", tokenId);
    const { tokens } = await this.getJson(mirrorUrl);
    if (tokens?.length) return;

    const key = typeof this.privateKey === "string"
      ? PrivateKey.fromStringECDSA(this.privateKey)
      : this.privateKey;
    const client = HederaClient.forName(this.network).setOperator(this.accountId, key);
    try {
      const response = await new TokenAssociateTransaction()
        .setAccountId(this.accountId).setTokenIds([ tokenId ]).execute(client);
      await response.getReceipt(client);
    } finally {
      client.close();
    }
  }
}

function selectAsset(paymentRequired, asset, network) {
  const wanted = asset
    ? ({ ...ASSET_IDS, usdc: USDC_IDS[network] }[asset.toLowerCase()] || asset)
    : paymentRequired.accepts?.[0]?.asset;
  const accepted = paymentRequired.accepts?.find((candidate) => candidate.asset === wanted);
  if (!accepted) throw new PrintwrightError(`server does not accept asset "${asset}"`);
  return accepted;
}

function integerId(value, name) {
  const id = Number(value);
  if (!Number.isSafeInteger(id) || id <= 0) throw new TypeError(`${name} must be a positive integer`);
  return id;
}

async function jsonBody(response) {
  const text = await response.text();
  if (!text) return {};
  try {
    return JSON.parse(text);
  } catch {
    throw new PrintwrightError(`expected JSON from ${response.url || "server"}`, {
      status: response.status, body: text,
    });
  }
}

function canonical(value) {
  return JSON.stringify(value, (_key, item) =>
    item && typeof item === "object" && !Array.isArray(item)
      ? Object.fromEntries(Object.keys(item).sort().map((key) => [ key, item[key] ]))
      : item);
}

function deepFreeze(value) {
  if (!value || typeof value !== "object" || Object.isFrozen(value)) return value;
  Object.values(value).forEach(deepFreeze);
  return Object.freeze(value);
}

export const assets = Object.freeze({
  testnet: Object.freeze({ usdc: USDC_IDS.testnet, hbar: ASSET_IDS.hbar }),
  mainnet: Object.freeze({ usdc: USDC_IDS.mainnet, hbar: ASSET_IDS.hbar }),
});
