# Printwright

**The agent-buyable marketplace for licensed 3D-printable models.** Designers set a per-print
royalty; buyers — human or AI agent — get the file plus a license, paid over
[x402](https://www.x402.org/) on [Hedera](https://hedera.com) testnet (HBAR or USDC), with every
purchase anchored as a tamper-evident **HCS license certificate** ("unit N of model X, licensed
at time T") that anyone can verify against the public mirror node.

DRM can't stop a printer, so Printwright doesn't sell copy protection. It makes **honesty
frictionless** — a sub-$1 royalty paid at machine speed, in one HTTP round-trip — and
**authorized units provable** — a $0.0001 public certificate per licensed unit, auditable by
anyone without trusting the marketplace. Card rails can do neither; both are native to x402
on Hedera.

No accounts. No cards. A purchase is one HTTP negotiation:

```
GET /api/v1/models/42/download?license=personal
  -> 402 Payment Required        (PaymentRequirements: amount, asset, payTo, feePayer)
  -> client signs a Hedera TransferTransaction (buyer signature only)
GET ... + PAYMENT-SIGNATURE header
  -> facilitator verifies & settles on-chain, sponsoring the network fee
  -> 200: file bundle + license + certificate + HashScan links
```

## JavaScript client

The reusable client used by both command-line and MCP buyers lives in [`client/`](client/).
From a checkout, install it with `npm install ./client` (the release package name is
`@printwright/client`):

```js
import { PrintwrightClient } from "@printwright/client";
const printwright = new PrintwrightClient({ baseUrl: "http://localhost:3000" });
const { models } = await printwright.search({ query: "cable clip", maxPriceCents: 300 });
const model = await printwright.get(models[0].id);
console.log(model.title, model.license_offers);
```

`search()` and `get()` need no credentials. `quote()` exposes the unsigned 402 for approval,
`buy()` signs locally with the configured Hedera account, `can()` answers structured license
use/quantity questions without parsing prose, and `verify()` compares the issued
certificate with its public HCS mirror message.

Independent verification does not need this Rails app. From this checkout,
`npx --package ./verifier printwright-verify pw-000058` scans the known public topic directly;
after the package release the shorter command is `npx printwright-verify pw-000058`. An exact
mirror-message URL can be supplied instead.
The frozen PWC-1 contract is published as [`/pwc-1.schema.json`](public/pwc-1.schema.json) and
documented in `/docs`; the verifier implementation lives in [`verifier/`](verifier/).
For a browser-native check, load [`public/printwright-verify-widget.js`](public/printwright-verify-widget.js)
as a classic script and add `<printwright-verify cert-id="…" topic-id="…" network="testnet">`.
The committed [`widget-example.html`](public/widget-example.html) runs from any static server and
queries only the Hedera mirror, so the marketplace can be offline.

**Try the complete integration without funds:** construct the client with `sandbox: true`, or
run `node scripts/buy.mjs --query "cable clip" --sandbox`. The app still returns a 402 and runs
verify → settle → certificate, but through its built-in mock facilitator and local throwaway
topic. Sandbox output is visibly fake and contains only a text receipt—never paid geometry.
The public [`conformance/`](conformance/) runner lints the raw x402 v2 challenge and completes
that sandbox contract with no credentials. The small
[`/agent-sellers`](app/views/pages/agent_sellers.html.erb) directory records other machine
endpoints whose unpaid challenges were manually checked.

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

## Mount it in an AI assistant (Scene 1b)

The MCP server exposes the same door to any MCP client (Claude Code, Claude Desktop, ...):

```bash
cd mcp && npm install && cd ..
claude mcp add printwright \
  --env PRINTWRIGHT_URL=http://localhost:3000 \
  --env BUYER_ACCOUNT_ID=0.0.xxxxxxx \
  --env BUYER_PRIVATE_KEY=0x... \
  --env MAX_SPEND_CENTS=500 \
  -- node mcp/server.mjs
```

Five tools: `search_models`, `get_model`, `buy_license` (refuses without `confirm: true`,
capped by `MAX_SPEND_CENTS`), `check_license` (machine-decidable use/quantity), and
`verify_certificate` (fetches the on-chain HCS message from
the public mirror node and diffs it against the marketplace copy). Then ask:
*"find a printable beaver with a hat under $3 and buy a personal license."*

## Run the marketplace locally

Prereqs: Ruby 3.3, Postgres (with `pg_trgm`), Node ≥ 20, OpenSCAD 2021.01+, and a funded
[Hedera testnet account](https://portal.hedera.com/dashboard) (the portal grants test HBAR;
testnet USDC comes from the [Circle faucet](https://faucet.circle.com) — pick Hedera).

```bash
sudo apt install postgresql-16-pgvector openscad  # or your platform's equivalent packages
cp .env.example .env                     # fill in the marked values
echo "HEDERA_PRIVATE_KEY=0x..." > sidecar/.env   # operator key stays with the signer
bin/setup --skip-server                  # bundle + db:prepare
bin/rails db:seed                        # 36 demo models
(cd sidecar && npm install && npm start) &        # HCS signing sidecar on :4021
bin/dev                                  # marketplace on :3000
```

**First-time setup — create your certificate topic (once):**

```bash
curl -X POST localhost:4021/create-topic -H "Authorization: Bearer $SIDECAR_TOKEN"
# -> {"topicId":"0.0.xxxxxxx"} — put it in .env as HEDERA_HCS_TOPIC_ID, then restart
#    BOTH the app and the sidecar (each reads the topic id at boot)
```

Troubleshooting: if your Postgres needs a password or a non-default socket, export
`DATABASE_URL` (e.g. `postgresql://user:pass@localhost/printwright_x402_development`).

The x402 facilitator is hosted ([Blocky402 testnet](https://blocky402.com), open access) —
nothing to run. It is not a single point of dependency: [`selfhost-facilitator/`](selfhost-facilitator/)
is a working fallback you can run yourself, and switching is one env var
(`X402_FACILITATOR_URL`). `docker-compose up` starts Postgres + sidecar if you prefer containers.

**Browser checkout:** the storefront's Buy button signs through a local demo-wallet daemon
(`BUYER_ACCOUNT_ID=... BUYER_PRIVATE_KEY=0x... node scripts/demo-wallet.mjs`) — a separate
key-holding process, the drop-in upgrade point for HashPack pairing.

**Shopkeeper chat:** `/chat` runs Gemini `gemini-3.1-flash-lite` server-side and dogfoods the
same public catalog API. Search works with purchases disabled. To enable testnet proposals,
set `CHAT_PURCHASES_ENABLED=true`, `CHAT_MAX_SPEND_CENTS`, and `CHAT_DAILY_SPEND_CENTS`.
Gemini can only prepare a proposal: a separate human button re-prices it, reserves the caps,
restricts settlement to exact USDC, and binds one signed transaction to that model/license.
Private keys remain in the wallet process; payment headers, receipts, and bearer download URLs
never enter the Gemini conversation. `CHAT_DAILY_MESSAGE_LIMIT` bounds total provider calls in
addition to the per-IP request rate limit.

Agent discovery: `/.well-known/x402-catalog.json` (crawlable live offers) ·
[`/openapi.json`](public/openapi.json) · [`/llms.txt`](public/llms.txt).
The public `/open-books` page and `/api/v1/stats` expose the HCS certificate count, configured
90/10 split, exact per-asset ledger totals, refunds, and recent raw mirror proof links.
The public `/chaos-log` page separates mirror-verifiable scheduled liveness from reproducible
adversarial test results; a heartbeat is never presented as proof that checkout is healthy.

Pre-release load sanity is a bounded, read-only catalog burst (100 requests stays below the
documented 120/min per-IP catalog limit):

```bash
node scripts/load-sanity.mjs --url https://your-host --requests 100 --concurrency 10
```

It requires a successful warm-up first, then reports status counts, transport errors,
throughput, and p50/p95/p99 latency. Non-local targets must use HTTPS.

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
bin/rails test:system     # Capybara: storefront + chat checkout, designer publish, verify states
cd sidecar && npm test    # sidecar suite (SDK faked)
cd mcp && npm test        # MCP stdio smoke (spawns the real server over stdio)
cd verifier && npm test   # PWC-1 validation + direct-mirror CLI contracts
```

All suites run on every push via GitHub Actions ([ci.yml](.github/workflows/ci.yml)), plus
rubocop, brakeman, a seeds boot, a tree-wide secret grep, and a log-hygiene grep that fails
the build if key/token/signature material ever reaches a log.

## On-chain artifacts (testnet)

- License certificate topic: [`0.0.9585069`](https://hashscan.io/testnet/topic/0.0.9585069)
- Example chat-approved purchase: [`0.0.7162784@1784422894.242015235`](https://hashscan.io/testnet/transaction/0.0.7162784@1784422894.242015235)
  with certificate `pw-000044` at [mirror message 45](https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9585069/messages/45)

## Why this needs Web3 (and Hedera specifically)

A 3D model license is a *right* — designers need per-print royalties (often under $1), buyers
increasingly are software (print servers, procurement agents), and both sides are global.
Card rails can't do sub-$1 fees, can't pay at machine speed, and can't onboard a designer in
minutes worldwide. x402-on-Hedera can: fixed sub-cent fees make micro-royalties viable, the
facilitator model means neither party runs infrastructure, and a $0.0001 HCS message gives
every license a public, tamper-evident receipt no Web2 service can match. Every purchase
generates a settlement transaction plus a consensus message; every buyer and designer is a
Hedera account.

## Post-bounty roadmap

- HashPack pairing as the browser signer (the demo-wallet daemon is the drop-in seam)
- Print-server royalty hook (OctoPrint): one `commercial_unit` purchase per job start
- On-chain royalty splits (designer + marketplace legs in one transfer)
- Mainnet + listing in the x402 ecosystem directory / x402scan

## Status / usage so far

Built solo during the Hedera x402 bounty week. Testnet receipts to date: 45 settled x402
purchases (HBAR and USDC), 45 anchored license certificates on
[topic 0.0.9585069](https://hashscan.io/testnet/topic/0.0.9585069), plus a fresh-clone
reproducibility rehearsal that reached a real settlement using only this README. Feedback
and issues welcome.

## License

MIT — see [LICENSE](LICENSE). The thirty-six demo models are self-authored, reproducible OpenSCAD
designs dedicated CC0-1.0; their source, dimensions, print orientation, caveats, and provenance
live in [`db/seed_assets/`](db/seed_assets/).
