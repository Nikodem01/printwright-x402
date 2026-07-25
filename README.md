# Printwright

**The agent-buyable marketplace for licensed 3D-printable models.** Designers set a per-print
royalty; buyers — human or AI agent — get the file plus a license, paid over
[x402](https://www.x402.org/) on [Hedera](https://hedera.com) testnet (HBAR or USDC), with every
purchase anchored as a tamper-evident **HCS license certificate** ("unit N of model X, licensed
at time T") that the holder can prove against the public mirror node.

DRM can't stop a printer, so Printwright doesn't sell copy protection. It makes **honesty
frictionless** — a sub-1-USDC royalty paid at machine speed, in one HTTP round-trip — and
**authorized units provable** — a $0.0001 anchor per licensed unit that anyone can check without
trusting the marketplace. Card rails can do neither; both are native to x402 on Hedera.

The anchor is an **opaque commitment**, not the certificate: the topic carries only
`SHA-256( domain ‖ nonce ‖ JCS(certificate) )`, so scraping it yields no buyer, no designer payout
wallet, and no per-model sales count. The certificate travels with the buyer as a **proof bundle**
and is disclosed by them; whoever they show it to recomputes the hash and compares it against the
ledger. Per-certificate proof is kept; broadcasting every designer's sales volume is not.

No accounts. No cards. A purchase is one HTTP negotiation:

```
GET /api/v1/models/42/download?license=personal
  -> 402 Payment Required        (PaymentRequirements: amount, asset, payTo, feePayer)
  -> client signs a Hedera TransferTransaction (buyer signature only)
GET ... + PAYMENT-SIGNATURE header
  -> facilitator verifies & settles on-chain, sponsoring the network fee
  -> 200: file bundle + license + certificate + proof bundle + HashScan links
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
use/quantity questions without parsing prose, and `verify()` recomputes the certificate's
commitment and compares it with the message anchored on the public HCS topic.

Independent verification does not need this Rails app. Every paid delivery includes a
`proof_bundle` — the certificate, its blinding nonce, the exact licensed terms text, and where the
commitment is anchored. From this checkout,
`npx --package ./verifier printwright-verify bundle.json` recomputes the commitment locally
(RFC 8785 canonicalization + SHA-256) and confirms it matches the Hedera mirror; after the package
release the shorter command is `npx printwright-verify bundle.json`. A `bundle_url` or `-` for
stdin works too. The mirror host is fixed in the verifier and its message URL derived from the
bundle's topic and sequence number, so a bundle can never nominate the "mirror" that blesses it.
The frozen PWC-1 contract — on-chain envelope, certificate, and proof bundle — is published as
[`/pwc-1.schema.json`](public/pwc-1.schema.json); the verifier implementation lives in
[`verifier/`](verifier/).
For a browser-native check, load [`public/printwright-verify-widget.js`](public/printwright-verify-widget.js)
as a classic script and add `<printwright-verify bundle-url="…" topic-id="…" network="testnet">`,
or paste the bundle inline. The committed [`widget-example.html`](public/widget-example.html) runs
from any static server and queries only the Hedera mirror, so the marketplace can be offline.
Paid delivery receipts also expose a 1200×630 certificate `share_card_url`. A capped offer reports
its license unit and current license slots remaining; the cap limits licenses sold, not physical
copies, and the storefront says so explicitly.
Real paid deliveries include a private durable receipt capability for later re-download. Buyers
may optionally attach a receipt to an email-only magic-link library; sandbox gets neither the
capability nor library eligibility. No buyer account or password is created.

Designers can bulk-import their own catalog ZIP or review a portable public HTTPS profile under
`/designer/imports`. The [`external-profile v1` schema](public/external-profile-v1.schema.json)
requires a source URL, source license, and SHA-256 for every remote file. Import is per-model and
warranty-gated: proprietary originals become drafts with provenance, while Creative Commons,
public-domain, missing, and unknown licenses stay blocked with explicit reasons. The importer does
not scrape undocumented Printables/Thingiverse HTML or silently re-license third-party work.

**Try the complete integration without funds:** construct the client with `sandbox: true`, or
run `node scripts/buy.mjs --query "cable clip" --sandbox`. The app still returns a 402 and runs
verify → settle → certificate, but through its built-in mock facilitator and local throwaway
topic. Sandbox output is visibly fake and contains only a text receipt—never paid geometry.
The public [`conformance/`](conformance/) runner lints the raw x402 v2 challenge and completes
that sandbox contract with no credentials.

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
`verify_certificate` (recomputes the commitment from the revealed certificate and checks it against
the on-chain HCS message on the public mirror node). Then ask:
*"find a printable beaver with a hat under 3 USDC and buy a personal license."*

## Run the marketplace locally

Prereqs: Ruby 3.3, Postgres (with `pg_trgm`), Node ≥ 20, OpenSCAD 2021.01+, and a funded
[Hedera testnet account](https://portal.hedera.com/dashboard) (the portal grants test HBAR;
testnet USDC comes from the [Circle faucet](https://faucet.circle.com) — pick Hedera).

```bash
sudo apt install postgresql-16-pgvector openscad  # or your platform's equivalent packages
cp .env.example .env                     # fill in the marked values
cp sidecar/.env.example sidecar/.env     # fill keys here; never in the Rails env
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

Production stores paid model files in a private S3-compatible bucket and runs an encrypted
custom-format PostgreSQL dump to that bucket nightly. See [docs/OPERATIONS.md](docs/OPERATIONS.md)
for the parameterized Kamal/pgvector/sidecar deployment, required storage and SMTP configuration,
Sentry smoke checks, on-demand backup, and guarded restore rehearsal steps.

The x402 facilitator is hosted ([Blocky402 testnet](https://blocky402.com), open access) —
nothing to run. It is not a single point of dependency, and reproducing this repo does not depend
on that service staying up: [`selfhost-facilitator/`](selfhost-facilitator/) is a working fallback
you can run yourself — the Hedera slice of the x402-foundation reference facilitator, on the
published `@x402/core` + `@x402/hedera` packages. `cd selfhost-facilitator && npm install`, copy
`.env.example` and give it a funded testnet account as fee payer, `node server.mjs`, then point the
app at it with the one env var `X402_FACILITATOR_URL=http://localhost:4023`. Nothing else changes:
the same 402, the same signed transfer, the same settle. For a run with no funds and no facilitator
at all, send `X-Sandbox: true`. `docker-compose up` starts pgvector/Postgres + sidecar if you prefer
containers; Compose reads the operator key only from `sidecar/.env`.

**Browser checkout:** set the public `WALLETCONNECT_PROJECT_ID` from Reown and register the exact
app origin. The Connect wallet control uses the maintained Hedera WalletConnect/AppKit native
adapter. HashPack (or another compatible Hedera wallet) signs and returns the exact x402 transfer;
the facilitator remains the transaction fee payer and the browser never submits or exposes a key.
The wallet bundle is locally hosted and loads only after Connect/Buy is clicked. For deterministic
development tests only, `DEMO_WALLET_URL=http://localhost:4022` enables
`scripts/demo-wallet.mjs` instead.

**Shopkeeper chat:** `/chat` runs Gemini `gemini-3.1-flash-lite` server-side and dogfoods the
same public catalog API. Search works with purchases disabled. The production deploy enables
testnet proposals with bounded 5 USDC per-conversation and 25 USDC daily defaults; override
`CHAT_PURCHASES_ENABLED`, `CHAT_MAX_SPEND_CENTS`, and `CHAT_DAILY_SPEND_CENTS` as needed.
Gemini can only prepare a proposal: a separate human button re-prices it, reserves the caps,
restricts settlement to exact USDC, and binds one signed transaction to that model/license.
Private keys remain in the wallet process; payment headers, receipts, and bearer download URLs
never enter the Gemini conversation. `CHAT_DAILY_VISITOR_MESSAGE_LIMIT` prevents one IP from
consuming the shared allowance; `CHAT_DAILY_PROVIDER_CALL_LIMIT` bounds every Gemini request,
including tool-loop follow-ups, in addition to the short per-IP burst limit.

Agent discovery: `/.well-known/x402-catalog.json` (crawlable live offers) ·
[`/openapi.json`](public/openapi.json) · [`/llms.txt`](public/llms.txt).
The public `/open-books` page and `/api/v1/stats` expose the HCS certificate count, configured
90/10 split, exact per-asset ledger totals, and recent raw mirror proof links.
The public `/chaos-log` page lists reproducible adversarial test results at the linked code revision.

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
cd verifier && npm test   # PWC-1 commitment + proof-bundle contracts (CLI and browser widget)
cd wallet && npm test     # browser transaction/header contract (no live wallet popup)
```

All suites run on every push via GitHub Actions ([ci.yml](.github/workflows/ci.yml)), plus
rubocop, brakeman, a seeds boot, a tree-wide secret grep, and a log-hygiene grep that fails
the build if key/token/signature material ever reaches a log.

## On-chain artifacts (testnet)

- License commitment topic: [`0.0.9585069`](https://hashscan.io/testnet/topic/0.0.9585069)
- Example purchase: [`0.0.7162784@1784976230.265183795`](https://hashscan.io/testnet/transaction/0.0.7162784@1784976230.265183795),
  commitment anchored at [mirror message 59](https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9585069/messages/59).
  The message reads, in full:

  ```json
  {"type":"printwright-license-commitment","version":1,"algorithm":"sha256-jcs-v1",
   "commitment":"d018923f613ed67e36e38f4aa1a9eec0b076fb7110c11490efbcf0368b0e74d6"}
  ```

  No model, designer, buyer, or count — that is the point. The buyer's proof bundle for this
  purchase is embedded in [`public/widget-example.html`](public/widget-example.html); open it
  from any static server, or run `node verifier/cli.js` against it, and the commitment
  recomputes to the value above.

## Why this needs Web3 (and Hedera specifically)

A 3D model license is a *right* — designers need per-print royalties (often under 1 USDC), buyers
increasingly are software (print servers, procurement agents), and both sides are global.
Card rails can't do sub-1-USDC fees, can't pay at machine speed, and can't onboard a designer in
minutes worldwide. x402-on-Hedera can: fixed sub-cent fees make micro-royalties viable, the
facilitator model means neither party runs infrastructure, and a $0.0001 HCS message gives
every license a tamper-evident anchor no Web2 service can match — one whose privacy is a design
choice, not a compromise, because the ledger holds a commitment rather than the certificate. Every
purchase generates a settlement transaction plus a consensus message; every buyer and designer is a
Hedera account.

## Hedera services used, and why each one

| Service | Where it is used | Why this service |
|---|---|---|
| **Consensus Service (HCS)** | one global topic (`0.0.9585069`) holds a license commitment per purchase and a `pwv-1` provenance event per model version | A license needs an ordered, timestamped, tamper-evident record that outlives us. The topic was created **without an admin key**, so nobody — including Printwright — can rewrite or delete it. Each record is one message, one sequence number: a provenance event that spanned chunks would not be a single atomic fact. |
| **Token Service (HTS)** | USDC settlement (`0.0.429274` testnet, `0.0.456858` mainnet) and designer payouts | Buyers pay a stable price in a real token rather than an amount that drifts between quote and settle, and payouts move the same asset back out. |
| **HBAR (native)** | the second accepted asset on every 402 | Some agents hold only HBAR; quotes are priced live from the mirror's exchange rate with a 3% match tolerance so a quote that drifts still verifies. |
| **Mirror node REST** | certificate verification, settle reconciliation, exchange rate, payout receivability | Every read goes to the public mirror, never to a consensus node — including the reads a *third party* makes, which is what makes verification independent of us. |
| **x402 `exact` scheme** | the paywall itself | The buyer signs a `TransferTransaction`; the facilitator verifies, sponsors the network fee, and settles. One HTTP round-trip, no account on our side. |
| **Wallet signatures** (`hedera_signMessage`) | proving a designer controls their payout account | Ownership is proved against the account's on-chain key, so Printwright never holds or needs a designer's key. |

Not used, deliberately: **an NFT license**. A transferable, royalty-bearing token contradicts a
license the terms make non-transferable and certificate-bound, and it gated nothing — see the
license terms and the removal in the history.

**Network impact per purchase.** One x402 settle (`CryptoTransfer`), one HCS message, and — when a
designer's payout is due — one further `TransferTransaction`, plus a one-time `TokenAssociate` the
first time a designer receives USDC. So a purchase is **2–3 mainnet-shaped transactions**, all
initiated by software rather than by a person clicking. Publishing a model version adds one more
HCS message. The audience is the part that compounds: print farms, procurement agents, and
OctoPrint servers that pay per job are transaction sources that do not exist on Hedera today, and
each one transacts per print rather than per session.

## Post-bounty roadmap

- Independent buyer/designer validation and public marketplace launch
- Print-server royalty hook (OctoPrint): one `commercial_unit` purchase per job start
- On-chain royalty splits (designer + marketplace legs in one transfer)
- Mainnet + listing in the x402 ecosystem directory / x402scan

## Status / usage so far

Built solo during the Hedera x402 bounty week. Testnet receipts to date: 47 settled x402
purchases (HBAR and USDC), 59 messages on
[topic 0.0.9585069](https://hashscan.io/testnet/topic/0.0.9585069) covering license commitments
and model-version provenance, plus a fresh-clone
reproducibility rehearsal that reached a real settlement using only this README. Feedback
and issues welcome.

## License

MIT — see [LICENSE](LICENSE). The thirty-six demo models are self-authored, reproducible OpenSCAD
designs dedicated CC0-1.0; their source, dimensions, print orientation, caveats, and provenance
live in [`db/seed_assets/`](db/seed_assets/).
