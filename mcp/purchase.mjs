// The x402 purchase flow used by the buy_license tool: same reference client
// as scripts/buy.mjs, returned as data instead of narrated to stdout.
import { x402Client, x402HTTPClient } from "@x402/core/client";
import { createClientHederaSigner, PrivateKey } from "@x402/hedera";
import { ExactHederaScheme } from "@x402/hedera/exact/client";

// Derived from HEDERA_NETWORK like every other network-dependent value in the
// project (scripts/buy.mjs, the sidecar, Hedera::Network). Hardcoding testnet
// here would silently keep this buyer on testnet while the rest of a mainnet
// deployment moved — the one switch has to flip everything or it flips nothing.
const NET = process.env.HEDERA_NETWORK === "mainnet" ? "mainnet" : "testnet";
const USDC = NET === "mainnet" ? "0.0.456858" : "0.0.429274"; // native USDC per network
const ASSET_IDS = { usdc: USDC, hbar: "0.0.0" };

export async function purchase({ base, modelId, license, asset, accountId, privateKey }) {
  const resourceUrl = `${base}/api/v1/models/${modelId}/download?license=${license}`;
  const leg1 = await fetch(resourceUrl, { headers: { accept: "application/json" } });
  if (leg1.status !== 402) {
    throw new Error(`expected 402 from ${resourceUrl}, got ${leg1.status}: ${await leg1.text()}`);
  }
  const required = await leg1.json();
  const wanted = asset ? ASSET_IDS[asset] : required.accepts[0].asset;
  const accept = required.accepts.find((a) => a.asset === wanted);
  if (!accept) throw new Error(`server does not accept asset "${asset}"`);

  const signer = createClientHederaSigner(accountId, PrivateKey.fromStringECDSA(privateKey), {
    network: `hedera:${NET}`,
  });
  const httpClient = new x402HTTPClient(new x402Client().register("hedera:*", new ExactHederaScheme(signer)));
  const paymentRequired = httpClient.getPaymentRequiredResponse((n) => leg1.headers.get(n), required);
  const payload = await httpClient.createPaymentPayload({ ...paymentRequired, accepts: [accept] });
  const headers = httpClient.encodePaymentSignatureHeader(payload);

  const leg2 = await fetch(resourceUrl, { headers: { accept: "application/json", ...headers } });
  const body = await leg2.json();
  if (leg2.status !== 200) {
    throw new Error(`payment failed (${leg2.status}): ${JSON.stringify(body)}`);
  }
  return body;
}
