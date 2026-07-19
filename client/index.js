import { x402Client, x402HTTPClient } from "@x402/core/client";
import { createClientHederaSigner, PrivateKey } from "@x402/hedera";
import { ExactHederaScheme } from "@x402/hedera/exact/client";
import { Client as HederaClient, TokenAssociateTransaction } from "@hiero-ledger/sdk";
import { randomUUID } from "node:crypto";

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
    sandbox = false,
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
    this.sandbox = sandbox;
    this.quotes = new WeakSet();
    this.batchQuotes = new WeakSet();
  }

  async search({ query, maxPriceCents, material, supports, category, collection } = {}) {
    if (!query?.trim()) throw new TypeError("query is required");

    const params = new URLSearchParams({ q: query });
    if (maxPriceCents !== undefined) params.set("max_price_cents", String(maxPriceCents));
    if (material) params.set("material", material);
    if (supports !== undefined) params.set("supports", String(supports));
    if (category) params.set("category", category);
    if (collection) params.set("collection", collection);
    return this.getJson(this.url(`api/v1/models?${params}`));
  }

  async get(modelId) {
    return this.getJson(this.url(`api/v1/models/${integerId(modelId, "modelId")}`));
  }

  async quote({ modelId, license = "personal", asset } = {}) {
    const id = integerId(modelId, "modelId");
    const resourceUrl = this.url(`api/v1/models/${id}/download?${new URLSearchParams({ license })}`);
    const headers = { accept: "application/json" };
    if (this.sandbox) headers["X-Sandbox"] = "true";
    const response = await this.fetch(resourceUrl, { headers });
    const paymentRequired = deepFreeze(await jsonBody(response));
    if (response.status !== 402) {
      throw new PrintwrightError(`expected 402 from ${resourceUrl}, got ${response.status}`, {
        status: response.status, body: paymentRequired,
      });
    }
    if (this.sandbox && paymentRequired.sandbox !== true) {
      throw new PrintwrightError("server did not return a sandbox payment requirement");
    }

    const accepted = selectAsset(paymentRequired, asset, this.network);
    const quote = Object.freeze({
      modelId: id,
      license,
      resourceUrl: resourceUrl.toString(),
      paymentRequired,
      accepted,
      sandbox: paymentRequired.sandbox === true,
      responseHeaders: Object.freeze(Object.fromEntries(response.headers)),
    });
    this.quotes.add(quote);
    return quote;
  }

  async buy({ modelId, license = "personal", asset, quote } = {}) {
    const purchaseQuote = quote || await this.quote({ modelId, license, asset });
    this.validateQuote(purchaseQuote);
    if (purchaseQuote.sandbox) return this.buySandbox(purchaseQuote);

    const headers = await this.paymentHeaders(purchaseQuote);
    const response = await this.fetch(purchaseQuote.resourceUrl, {
      headers: { accept: "application/json", ...headers },
    });
    const body = await jsonBody(response);
    if (!response.ok) {
      throw new PrintwrightError(`payment failed (${response.status})`, { status: response.status, body });
    }
    return body;
  }

  async quoteBatch({ items, asset, webhook } = {}) {
    const normalized = normalizeBatchItems(items);
    const normalizedWebhook = normalizeWebhook(webhook);
    const resourceUrl = this.url("api/v1/batches");
    const requestBody = JSON.stringify(batchBody(normalized, normalizedWebhook));
    const headers = { accept: "application/json", "content-type": "application/json" };
    if (this.sandbox) headers["X-Sandbox"] = "true";
    const response = await this.fetch(resourceUrl, { method: "POST", headers, body: requestBody });
    const paymentRequired = deepFreeze(await jsonBody(response));
    if (response.status !== 402) {
      throw new PrintwrightError(`expected 402 from ${resourceUrl}, got ${response.status}`, {
        status: response.status, body: paymentRequired,
      });
    }
    if (this.sandbox && paymentRequired.sandbox !== true) {
      throw new PrintwrightError("server did not return a sandbox payment requirement");
    }

    const quote = Object.freeze({
      items: deepFreeze(normalized),
      webhook: deepFreeze(normalizedWebhook),
      resourceUrl: resourceUrl.toString(),
      requestBody,
      paymentRequired,
      accepted: selectAsset(paymentRequired, asset, this.network),
      sandbox: paymentRequired.sandbox === true,
      responseHeaders: Object.freeze(Object.fromEntries(response.headers)),
    });
    this.batchQuotes.add(quote);
    return quote;
  }

  async buyBatch({ items, asset, webhook, quote } = {}) {
    const purchaseQuote = quote || await this.quoteBatch({ items, asset, webhook });
    this.validateBatchQuote(purchaseQuote);
    if (purchaseQuote.sandbox) return this.buySandbox(purchaseQuote);

    const paymentHeaders = await this.paymentHeaders(purchaseQuote);
    const response = await this.fetch(purchaseQuote.resourceUrl, {
      method: "POST",
      headers: { accept: "application/json", "content-type": "application/json", ...paymentHeaders },
      body: purchaseQuote.requestBody,
    });
    const body = await jsonBody(response);
    if (!response.ok) {
      throw new PrintwrightError(`batch payment failed (${response.status})`, { status: response.status, body });
    }
    return body;
  }

  async verify(certId) {
    if (!certId?.trim()) throw new TypeError("certId is required");

    const ours = await this.getJson(this.url(`api/v1/certificates/${encodeURIComponent(certId)}`));
    if (!["anchored", "sandbox"].includes(ours.status)) return { ...ours, match: null };

    let mirror;
    try {
      mirror = await this.getJson(new URL(ours.hcs.mirror_url, this.baseUrl));
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

  async can({ certId, use, qty = 1 } = {}) {
    if (!certId?.trim()) throw new TypeError("certId is required");
    if (!use?.trim()) throw new TypeError("use is required");
    if (!Number.isSafeInteger(qty) || qty <= 0) throw new TypeError("qty must be a positive integer");

    const params = new URLSearchParams({ use, qty: String(qty) });
    return this.getJson(this.url(`api/v1/licenses/${encodeURIComponent(certId)}/can?${params}`));
  }

  async reportPrint({ certId, receiptToken } = {}) {
    if (!certId?.trim()) throw new TypeError("certId is required");
    if (!receiptToken?.trim()) throw new TypeError("receiptToken is required");
    const url = this.url(`api/v1/licenses/${encodeURIComponent(certId)}/print_reports`);
    const response = await this.fetch(url, {
      method: "POST",
      headers: { accept: "application/json", "content-type": "application/json" },
      body: JSON.stringify({ receipt_token: receiptToken }),
    });
    const body = await jsonBody(response);
    if (!response.ok) {
      throw new PrintwrightError(`print report failed (${response.status})`, { status: response.status, body });
    }
    return body;
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

  async buySandbox(quote) {
    const payload = {
      x402Version: 2,
      resource: quote.paymentRequired.resource,
      accepted: quote.accepted,
      payload: { transaction: `sandbox:${randomUUID()}` },
    };
    const response = await this.fetch(quote.resourceUrl, {
      method: quote.requestBody ? "POST" : "GET",
      body: quote.requestBody,
      headers: {
        accept: "application/json",
        ...(quote.requestBody ? { "content-type": "application/json" } : {}),
        "X-Sandbox": "true",
        "PAYMENT-SIGNATURE": Buffer.from(JSON.stringify(payload)).toString("base64"),
      },
    });
    const body = await jsonBody(response);
    if (!response.ok) {
      throw new PrintwrightError(`sandbox payment failed (${response.status})`, {
        status: response.status, body,
      });
    }
    if (body.sandbox !== true) throw new PrintwrightError("server returned an unlabeled sandbox receipt");
    return body;
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

  validateBatchQuote(quote) {
    if (!quote || !this.batchQuotes.has(quote)) {
      throw new TypeError("quote must come from this client.quoteBatch()");
    }
    if (quote.resourceUrl !== this.url("api/v1/batches").toString()) {
      throw new TypeError("quote belongs to a different Printwright endpoint");
    }
    if (quote.requestBody !== JSON.stringify(batchBody(quote.items, quote.webhook))) {
      throw new TypeError("batch quote body changed after negotiation");
    }
    const offered = quote.paymentRequired.accepts?.some((candidate) =>
      canonical(candidate) === canonical(quote.accepted));
    if (!offered) throw new TypeError("quote selection is not in the server payment requirements");
  }

  async paymentHeaders(quote) {
    this.requireSigner();
    if (this.autoAssociate && quote.accepted.asset === USDC_IDS[this.network]) {
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
      (name) => quote.responseHeaders[name.toLowerCase()] || null,
      quote.paymentRequired
    );
    const payload = await httpClient.createPaymentPayload({ ...required, accepts: [ quote.accepted ] });
    return httpClient.encodePaymentSignatureHeader(payload);
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

function normalizeBatchItems(items) {
  if (!Array.isArray(items) || items.length < 1 || items.length > 20) {
    throw new TypeError("items must contain 1 to 20 licenses");
  }
  return items.map((item, index) => ({
    model_id: integerId(item?.modelId ?? item?.model_id, `items[${index}].modelId`),
    license: item?.license || "personal",
  }));
}

function normalizeWebhook(webhook) {
  if (webhook === undefined) return undefined;
  let url;
  try {
    url = new URL(webhook?.url);
  } catch {
    throw new TypeError("webhook.url must be a valid public HTTPS URL");
  }
  if (url.protocol !== "https:" || url.port || url.username || url.password || url.hash) {
    throw new TypeError("webhook.url must use HTTPS on port 443 without credentials or a fragment");
  }
  const secretBytes = typeof webhook?.secret === "string" ? Buffer.byteLength(webhook.secret) : 0;
  if (secretBytes < 32 || secretBytes > 256) {
    throw new TypeError("webhook.secret must be 32 to 256 bytes");
  }
  return { url: webhook.url, secret: webhook.secret };
}

function batchBody(items, webhook) {
  return webhook ? { items, webhook } : { items };
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
