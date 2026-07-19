# @printwright/client

The Node.js client for the Printwright licensed 3D-model marketplace. It searches the public
catalog, negotiates and signs x402 payments on Hedera, and independently compares license
certificates with their HCS mirror-node messages.

```bash
npm install @printwright/client
```

Catalog reads need no account:

```js
import { PrintwrightClient } from "@printwright/client";
const printwright = new PrintwrightClient({ baseUrl: "https://printwright.example" });
const { models } = await printwright.search({ query: "cable clip", maxPriceCents: 300 });
const model = await printwright.get(models[0].id);
console.log(model.title, model.license_offers);
```

Buying requires a funded Hedera account. The key stays in this process and signs locally; it
is never sent to Printwright. A first USDC purchase automatically associates the token if
needed (set `autoAssociate: false` to manage association yourself).

```js
const buyer = new PrintwrightClient({
  baseUrl: "https://printwright.example",
  accountId: process.env.BUYER_ACCOUNT_ID,
  privateKey: process.env.BUYER_PRIVATE_KEY,
  network: "testnet",
});
const receipt = await buyer.buy({ modelId: model.id, license: "personal", asset: "usdc" });
const proof = await buyer.verify(receipt.license.cert_id);
console.log(receipt.hashscan_url, proof.match);
```

`quote()` exposes the unsigned 402 requirements for approval or dry-run interfaces. Pass its
result back as `buy({ quote })` to sign exactly that selection without requesting another
quote.

For a full zero-funds integration rehearsal, set `sandbox: true` and omit credentials:

```js
const sandbox = new PrintwrightClient({ baseUrl: "http://localhost:3000", sandbox: true });
const receipt = await sandbox.buy({ modelId: 1, license: "personal" });
const proof = await sandbox.verify(receipt.license.cert_id);
```

This still performs a 402, mock verification, mock settlement, and certificate lookup. It
returns a non-printable text receipt and a local throwaway-topic message. Every artifact is
labeled sandbox; none is a Hedera transaction, real license, or proof of payment.

The current Hiero SDK pins older transitive versions even though patched same-major releases
exist. npm applications should carry the same overrides as this repository until Hiero rolls
them forward: `@grpc/grpc-js` 1.14.4, `protobufjs` 8.7.1, and `ethers > ws` 8.21.1.

Requires Node 20 or newer. MIT licensed.
