# Self-hosted x402 facilitator (fallback)

Printwright uses the hosted [Blocky402](https://blocky402.com) facilitator by default —
nothing to run. This directory is the **self-host fallback**: a minimal facilitator you can
run yourself so the marketplace depends on no single provider. x402 is permissionless; the more
independent Hedera facilitators exist, the healthier the rail.

It is the Hedera slice of the [x402-foundation reference facilitator](https://github.com/x402-foundation/x402/blob/main/examples/typescript/facilitator/advanced/all_networks.ts),
standalone on the published [`@x402/core`](https://www.npmjs.com/package/@x402/core) +
[`@x402/hedera`](https://www.npmjs.com/package/@x402/hedera) packages. It exposes the exact
`GET /supported`, `POST /verify`, `POST /settle` contract Printwright's `FacilitatorClient`
speaks, so switching is a **single environment variable**.

## Run it

```bash
cd selfhost-facilitator
npm install
cp .env.example .env      # set HEDERA_ACCOUNT_ID + HEDERA_PRIVATE_KEY (ECDSA fee-payer)
node server.mjs           # -> self-host x402 facilitator on http://localhost:4023
```

Port 4023 by default — the browser demo-wallet daemon already owns 4022, and you may want both
running at once. `GET http://localhost:4023/supported` should advertise your fee-payer:

```json
{ "kinds": [ { "x402Version": 2, "scheme": "exact", "network": "hedera:testnet",
              "extra": { "feePayer": "0.0.YOURACCT" } } ] }
```

## Point Printwright at it

```bash
X402_FACILITATOR_URL=http://localhost:4023 bin/rails server
```

That is the whole switch. The app discovers the fee-payer from `/supported`, injects it into
every `402`, and routes `verify`/`settle` here. No code change.

## Fee-payer safety

The fee-payer sponsors the network fee and submits the buyer's signed transfer — it must never
be a **party to the value transfer**. If the fee-payer is also the buyer (or the payTo), the
scheme rejects the payment with `invalid_exact_hedera_payload_fee_payer_transferring_hbar`.
Use three distinct accounts: buyer → payTo, fee-payer sponsors.

## Exposure

`/verify` and `/settle` are unauthenticated — facilitators are public by design, and the hosted
one is open access too. The fee-payer never gains or loses value (it submits the *buyer's* signed
transfer), so the worst a stranger can do is burn its network fees, a few hundredths of a cent at
a time. Still, treat the port as a spend surface: keep it on localhost or behind your proxy unless
you mean to run a public facilitator, and fund the fee-payer with operating float, not a treasury.

## Verified (Hedera testnet)

Real settles driven end-to-end through this facilitator (`scripts/buy.mjs` → app → here), one
per asset. In each, the mirror confirms the value moved buyer → designer and the fee-payer
`0.0.9067781` moved **zero** value, paying only the network fee:

| asset | settle tx | value moved | fee-payer paid | cert |
|---|---|---|---|---|
| HBAR | [`0.0.9067781@1784389444.403626092`](https://hashscan.io/testnet/transaction/0.0.9067781@1784389444.403626092) | `0.0.9613501` −1358695652 tℏ → `0.0.9604186` +1358695652 tℏ | 301932 tℏ fee only | `pw-000036` (seq 37) |
| USDC | [`0.0.9067781@1784389148.249562065`](https://hashscan.io/testnet/transaction/0.0.9067781@1784389148.249562065) | `0.0.9613501` −0.90 → `0.0.9604186` +0.90 (`0.0.429274`) | 1660627 tℏ fee only | `pw-000033` (seq 34) |

Certificates anchored on topic [`0.0.9585069`](https://hashscan.io/testnet/topic/0.0.9585069).
The settle transaction's *payer* is this facilitator's fee-payer rather than the hosted one's
`0.0.7162784` — which is itself the proof the payment was routed here.

## Other networks

The upstream `all_networks.ts` also registers EVM, Solana, Stellar, Aptos, and more from the
same `x402Facilitator`. Add their schemes here the same way if you need a multi-chain endpoint.
