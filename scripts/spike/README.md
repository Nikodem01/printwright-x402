# x402 wire spike (Hedera testnet)

Minimal end-to-end proof that the x402 `exact` scheme settles on Hedera testnet through the
hosted [Blocky402](https://blocky402.com) facilitator, using the official `@x402/core` +
`@x402/hedera` packages. This is the reference wiring the Rails paywall reproduces; the
`wire-log/` captures are the ground truth (and test fixtures) for that implementation.

## Result (2026-07-15)

One real paid request: `GET /premium` → `402` → partially-signed `TransferTransaction`
(0.1 HBAR) → `PAYMENT-SIGNATURE` retry → facilitator verify + settle → `200`.

- Settled tx: [`0.0.7162784@1784125705.137810120`](https://hashscan.io/testnet/transaction/0.0.7162784@1784125705.137810120)
- Mirror node result `SUCCESS`: payer `0.0.9067781` −0.1 ℏ, treasury `0.0.9584959` +0.1 ℏ,
  facilitator fee payer `0.0.7162784` net-zero on value (paid the network fee only).

### Wire facts verified against the live stack (v2.18.0)

| Question | Answer |
|---|---|
| Payment header the v2 client emits | `PAYMENT-SIGNATURE` only (`X-PAYMENT` is v1-compat, not sent) |
| 402 response | `PAYMENT-REQUIRED` header (base64 JSON) **and** JSON body |
| Success response | `PAYMENT-RESPONSE` header (base64 JSON) |
| `/verify` request shape | `{x402Version, paymentPayload, paymentRequirements}` |
| `/verify` response | `{isValid, payer}` |
| `/settle` response key | **`transaction`** (`"0.0.7162784@<sec>.<nanos>"`), not `transactionId` |
| Hedera SDK the mechanism uses | `@hiero-ledger/sdk` (the renamed `@hashgraph/sdk`) |

## Files

- `server.mjs` — resource server, one paid route (`GET /premium`, 0.1 HBAR), logs all wire traffic
- `client.mjs` — buyer client, driven leg-by-leg so every byte is logged
- `facilitator-proxy.mjs` — transparent logging proxy in front of Blocky402 (`/verify`, `/settle` captures)
- `create-treasury.mjs` — one-time treasury account setup
- `wire-log/*.jsonl` — raw captures from the successful run (no secrets travel on the wire)

## Run it

```bash
npm install
cp ../../.env.example .env   # fill HEDERA_ACCOUNT_ID, HEDERA_PRIVATE_KEY (funded testnet account)
node create-treasury.mjs     # once; put the printed id in .env as TREASURY_ACCOUNT_ID
node facilitator-proxy.mjs & # :4403 → Blocky402
node server.mjs &            # :4402
node client.mjs              # pays 0.1 HBAR, prints the HashScan link
```
