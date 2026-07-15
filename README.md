# Printwright

**The agent-buyable marketplace for licensed 3D-printable models.** Designers set a per-print
royalty; buyers — human or AI agent — get the file plus a license, paid over
[x402](https://www.x402.org/) on [Hedera](https://hedera.com) testnet (HBAR or USDC), with every
purchase anchored as a tamper-evident **HCS license certificate** ("unit N of model X, licensed
at time T") that anyone can verify against the public mirror node.

No accounts. No cards. A purchase is one HTTP negotiation:

```
GET /api/v1/models/42/download?license=personal
  -> 402 Payment Required        (PaymentRequirements: amount, asset, payTo, feePayer)
  -> client signs a Hedera TransferTransaction (buyer signature only)
GET ... + PAYMENT-SIGNATURE header
  -> facilitator verifies & settles on-chain, sponsoring the network fee
  -> 200: file bundle + license + certificate + HashScan links
```

## Buy a model from the command line (Scene 1a)

```bash
npm install
export BUYER_ACCOUNT_ID=0.0.xxxxxxx        # funded Hedera testnet account
export BUYER_PRIVATE_KEY=0x...             # its hex ECDSA key (never sent anywhere)
node scripts/buy.mjs --query "beaver hat" --asset usdc --max-price 300
```

The script searches the catalog, prints the raw 402 `PaymentRequired` object, signs the
transfer, retries, and saves the STL plus `certificate.json` under `purchases/<slug>/`,
printing the HashScan transaction link and the HCS mirror-node link for the certificate.
`--dry-run` stops after the 402 (no payment) — useful as a smoke test.

## Run the marketplace locally

Prereqs: Ruby 3.3, Postgres, Node ≥ 20.

```bash
cp .env.example .env          # fill in Hedera testnet account + topic (see comments)
bin/setup --skip-server       # bundle + db:prepare
bin/rails db:seed             # 3 demo models
bin/dev                       # marketplace on :3000
cd sidecar && npm install && npm start   # HCS signing sidecar on :4021
```

The x402 facilitator is hosted ([Blocky402 testnet](https://blocky402.com), open access) —
nothing to run. `docker-compose up` starts Postgres + sidecar if you prefer containers.

## Architecture

- **Rails 8 monolith** — catalog API, x402 paywall (402 issuance, verify/settle via the
  facilitator, replay protection, settle-timeout reconciliation via mirror node), licenses
  with per-offer serials, expiring download grants.
- **HCS signing sidecar** (`sidecar/`, Node) — the only process holding a Hedera key; creates
  the certificate topic and submits cert messages. Certificate minting is async: a sidecar
  outage never blocks a paid download, certs backfill on retry.
- **Agent clients** (`scripts/`) — the bare buyer script above; `scripts/spike/` holds the
  original wire spike whose captures double as test fixtures.

## Tests

```bash
bin/rails test            # Rails suite (paywall error table runs against real captured wire bytes)
cd sidecar && npm test    # sidecar suite (SDK faked)
```

## On-chain artifacts (testnet)

- License certificate topic: [`0.0.9585069`](https://hashscan.io/testnet/topic/0.0.9585069)
- Example settled purchase: [`0.0.7162784@1784141006.971945408`](https://hashscan.io/testnet/transaction/0.0.7162784@1784141006.971945408)
  with its certificate at [mirror message 4](https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9585069/messages/4)

## License

MIT — see [LICENSE](LICENSE). Demo seed models are self-authored placeholder solids (CC0).
