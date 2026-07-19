# Operations runbook

Money moved on-chain is never rolled back — every procedure here moves state
*forward* (deliver, pay out, refund) or marks it honestly failed. All commands
run from the app root. The sidecar must be running (started **from `sidecar/`**,
it reads `sidecar/.env` for its keys) — and restarted after any migration or
topic change.

## Operator panel

The application-state procedures in this runbook—stale-purchase reconciliation, refunds,
certificate retries, payout previews/runs, designer identity and payout verification, and
ledger inspection—are also available at `/admin`. They call the same service objects as the
commands below; there is no second recovery implementation. Every attempted mutation records
the authenticated operator, request id, source address, subject and result in the immutable
`AdminAuditLog` table. Sandbox rehearsals are excluded from every money control.

Bootstrap or revoke an operator from the shell (the panel cannot grant its own access):

```bash
ADMIN_EMAIL=operator@example.com bin/rails admin:grant
ADMIN_EMAIL=operator@example.com bin/rails admin:revoke
```

The panel is session-authenticated, requires the separate `admin` grant, keeps Rails CSRF
protection, and rate-limits both views and mutations. Actions that change process configuration
or require a demo buyer key—smoke, buyer funding, facilitator startup and network switching—
remain external-only by design. Moving those keys into Rails to make them web buttons would
violate the custody map at the end of this document.

## First production deploy (Kamal)

`config/deploy.yml` is a single-host topology: kamal-proxy terminates TLS, the Rails container
runs Solid Queue inside Puma, and private-network accessories run pgvector/Postgres and the HCS
sidecar. The sidecar is a separate image and is the only container receiving Hedera private keys.
Copy `.env.example` values into the operator shell or a password manager; `.kamal/secrets` contains
only indirection and must never contain literal values.

Build and push the two images, validate the rendered manifest, then boot accessories before setup:

```bash
docker build -t "$SIDECAR_IMAGE" sidecar && docker push "$SIDECAR_IMAGE"
bin/kamal config
bin/kamal accessory boot db
bin/kamal accessory boot sidecar
bin/kamal setup
```

DNS for `APP_HOST` must already point to `DEPLOY_HOST`, with inbound 80/443 open for Let's Encrypt.
The database initializer creates the cache, queue and cable databases; Rails migrations enable
`vector` in the primary pgvector image. Verify the target and background worker:

```bash
bin/kamal app exec 'bin/rails runner "puts ActiveRecord::Base.connection.extension_enabled?(:vector)"'
bin/kamal app exec 'bin/rails runner "puts SolidQueue::Process.count"'
curl --fail "https://$APP_HOST/up"
```

Production SMTP raises delivery errors. After configuring the sender, request a designer password
reset and a buyer-library link through the public UI, then confirm both arrive and open the expected
HTTPS origin. Configure an external uptime monitor against `https://$APP_HOST/up`; `/up` is process
health only, so retain the paid smoke and HCS heartbeat checks below.

## Error monitoring

Rails requests, Solid Queue jobs and the Node sidecar report to Sentry when `SENTRY_DSN` is set.
Both SDKs disable default PII, tracing defaults off, and `SENTRY_TRACES_SAMPLE_RATE` is bounded to
0..1. The sidecar tags its boundary but sends no request body; client responses and local logs expose
only the exception class, not SDK messages or signed payloads. With no DSN both processes stay inert.

After creating the provider project and deploying, send one marker from each process:

```bash
bin/kamal app exec 'bin/rails runner "Sentry.capture_message(%q[rails-monitor-smoke]); Sentry.flush(2)"'
bin/kamal accessory exec sidecar 'node --import ./instrument.mjs --input-type=module -e \
  "import * as Sentry from \"@sentry/node\"; Sentry.captureMessage(\"sidecar-monitor-smoke\"); await Sentry.flush(2000)"'
```

Confirm both events have the expected environment and no request body, cookie, email, bearer token,
private key or signed transaction. Then configure alerts for new errors, repeated background-job
failures and sidecar `hedera_error` bursts. A provider dashboard check remains required after every
DSN or release change.

Clone reproducibility was rechecked on 2026-07-20: `DATABASE_URL` pointed `db:schema:load` at a
new scratch PostgreSQL database, which loaded 24 public tables with both `vector` and `pg_trgm`;
the named scratch database was then removed. PostgreSQL with pgvector remains an explicit README
prerequisite and deploys from `pgvector/pgvector:pg16`.

## Daily / after any incident: smoke

```bash
BUYER_ACCOUNT_ID=0.0.x BUYER_PRIVATE_KEY=0x... node scripts/smoke.mjs
```

Green = app, sidecar, facilitator, a real settle, and a mirror-confirmed cert.
A red smoke outranks every other task.

## Private model storage and database backups

Production uses the private `production_s3` Active Storage service. The bucket must deny public
access; a redeemed Printwright download grant redirects through Rails to a provider-signed URL
that expires after `STORAGE_URL_TTL_MINUTES` (10 minutes by default). Configure the `S3_*` values
from `.env.example`; `S3_ENDPOINT` is optional for AWS and required for most compatible providers.
Production refuses to boot without the bucket and access credentials.

Solid Queue runs `DatabaseBackupJob` nightly at 02:15. It calls `pg_dump --format=custom` without
putting the database password in argv and uploads an AES-256 server-side-encrypted object under
`BACKUP_S3_PREFIX`. Run and inspect one on demand:

```bash
bin/rails backups:database
# Confirm the printed key exists in the private bucket and has the provider's retention policy.
```

Restore rehearsals must target a newly created, non-production database. Download a selected dump
to a temporary operator path, create a scratch database, restore it, and compare critical counts:

```bash
createdb printwright_restore_rehearsal
pg_restore --no-owner --no-privileges --dbname printwright_restore_rehearsal /tmp/printwright.dump
psql printwright_restore_rehearsal -c 'select count(*) from models3d'
psql printwright_restore_rehearsal -c 'select count(*) from licenses'
dropdb printwright_restore_rehearsal
```

Never use `--clean` or point a rehearsal at the production database. On 2026-07-19 the local
custom-format rehearsal restored schema version `20260719235500`, 36 model rows and the expected
zero local license rows, then removed only the named scratch database and temporary dump. The
provider upload/download rehearsal remains pending until V20's owner-created bucket exists.

## Public HCS heartbeat

The production scheduler submits one compact PWH-1 liveness statement every six hours to a
dedicated, submit-key-protected topic. Create it once through the local sidecar, then set the
returned public topic id as `HEDERA_HEARTBEAT_TOPIC_ID` for both app and sidecar and restart them:

```bash
curl -X POST localhost:4021/create-heartbeat-topic \
  -H "Authorization: Bearer $SIDECAR_TOKEN" -H "Content-Type: application/json" -d '{}'
bin/rails runner 'HeartbeatJob.perform_now'
```

`/chaos-log` reads the latest message directly from the mirror. The topic has the operator as
admin, submit, and auto-renew account; the private key stays in the sidecar. A missing/invalid
mirror message is shown as unavailable, never replaced by `/up`. The heartbeat proves the Rails
scheduler and sidecar reached HCS at that instant—not end-to-end checkout health. The paid smoke
above remains the stronger operational test.

## Designer payouts

Panel: `/admin` → **Preview designer payouts** or **Run designer payouts**. The run button has
an explicit confirmation and the same database advisory lock as the command.

```bash
DRY_RUN=1 bin/rails ledger:payout   # preview per-designer totals per asset
bin/rails ledger:payout             # one batched tx per asset, HashScan links printed
```

- Only designers whose payout account passed the mirror check are paid; the
  rest stay owed (visible via `LedgerEntry.owed`).
- Runs are serialized by a DB advisory lock; still, run it from one shell.
- Crash between the on-chain transfer and the ledger write: the tx memo is
  `printwright designer payout <date>` — check the treasury account on
  HashScan for a payout tx with today's memo **before** re-running.

## Refunds

Panel: `/admin` → filter purchases to **Settled** → **Refund #…**.

Qualifies: `settled` (paid, never delivered) purchases — typically
`error_reason=sold_out_after_payment` from the pre-V5 window or a reaper
`settled_sold_out_refund_candidate`. Delivered purchases keep their license;
purchases whose designer share was already paid out need a manual clawback
decision first (the task refuses them).

```bash
PURCHASE_ID=42 bin/rails ledger:refund
```

Sends the full gross treasury -> buyer with memo
`printwright refund <replay_key[0,32]>`, records a `refund` ledger row (which
also removes the share from the owed balance), and moves the purchase to
`refunded`.

## Stale in-flight purchases (capacity holders)

Panel: `/admin` → **Reap stale purchases** for the batch, or **Reconcile #…** for one row.

Signed payments whose settle never concluded hold `max_units` capacity.

```bash
MINUTES=30 bin/rails purchases:reap
```

Per stale purchase: mirror shows the credit -> rolled forward to delivered
(cert re-anchored); no credit -> failed, capacity freed; mirror unreachable ->
skipped (never fail blind).

## Stuck certificate (license minting forever)

Panel: `/admin` → **Certificates waiting for HCS** → **Retry pw-…**. The persistent web process
enqueues the idempotent job; the shell fallback below uses `perform_now` because a runner's
in-process queue is not persistent.

`no_topic_configured` retries automatically once the sidecar restarts with
`HEDERA_HCS_TOPIC_ID` set. To re-anchor manually:

```bash
bin/rails runner 'CertMintJob.perform_now(License.find_by!(cert_id: "pw-000011").id)'
```

(`perform_now`, not `perform_later` — a runner's in-process queue dies with it.)

## Demo buyer out of funds

Testnet accounts drain after a run of demos. `smoke.mjs` checks the buyer's
balance before it tries to settle, so this surfaces as a named shortfall rather
than the facilitator's opaque `invalid_exact_hedera_payload_preflight_failed`.
Top up from the operator account:

```bash
node scripts/fund-buyer.mjs --dry-run    # shows both balances, sends nothing
node scripts/fund-buyer.mjs              # default: 200 ℏ + $20 USDC
```

The buyer must already be associated with USDC to receive it (`buy.mjs`
associates automatically on its first USDC purchase). Check headroom before a
recording session — each purchase costs the offer price plus a fraction of a
cent in network fees.

## Facilitator outage (hosted endpoint down)

The circuit breaker opens after 3 consecutive failures and 402s stop being
issued for 30s at a time. If the hosted facilitator stays down, run the
fallback and repoint the app — no code change, no redeploy of anything else:

```bash
cd selfhost-facilitator && npm install
cp .env.example .env    # funded ECDSA fee-payer; NOT any buyer or payTo account
node server.mjs         # -> :4023, advertises its feePayer on GET /supported
```

Then restart the app with `X402_FACILITATOR_URL=http://localhost:4023`. The
fee-payer in every new `402` comes from `/supported`, so in-flight payments
signed against the old fee-payer must be re-quoted — reap them
(`MINUTES=0 bin/rails purchases:reap`) rather than leaving capacity held.
Verified end-to-end on testnet: see that directory's README.

## Mainnet path

One switch: `HEDERA_NETWORK=mainnet` (app, sidecar, and buyer-script env).
Everything network-dependent derives from it — CAIP-2 network id, native USDC
(`0.0.456858` mainnet / `0.0.429274` testnet, both 6 decimals, per
docs.hedera.com), mirror node, and HashScan links. `MIRROR_NODE_URL` still
overrides the mirror if needed.

Also required for a real mainnet launch:
- a mainnet operator + treasury account (fund with real HBAR), keys in
  `sidecar/.env` exactly as on testnet;
- an `X402_FACILITATOR_URL` that supports `hedera:mainnet` (check
  `/supported`);
- a fresh HCS topic (`/create-topic` via the sidecar, then restart it);
- reviewed legal text replacing the template ToS/privacy pages.

Boot check without spending: start the app with `HEDERA_NETWORK=mainnet` and
`curl /up`, then GET any model's download URL — the 402 must quote
`hedera:mainnet` and `0.0.456858`. Nothing settles until a buyer signs.

### What operations cost (approximate, USD-pegged network fees)

| operation | fee | when |
|---|---|---|
| HCS message (the certificate) | $0.0001 | every purchase |
| token transfer (settle leg) | $0.0001–0.001 | every purchase (facilitator pays) |
| NFT mint + airdrop | ~$0.03–0.10 | every purchase with an account buyer |
| NFT collection create | ~$1 | once per designer |
| account create (demo/testing) | $0.05 | rare |
| HCS topic create | $0.01 | once |

## Key custody map

| key | lives in | used for |
|---|---|---|
| operator (`HEDERA_PRIVATE_KEY`) | `sidecar/.env` only | HCS submits, payout tx fees |
| treasury (`TREASURY_PRIVATE_KEY`) | `sidecar/.env` only | payout/refund debits |
| buyer (`BUYER_PRIVATE_KEY`) | operator's shell env | demo purchases |

The Rails process never loads a private key. Never add one to `.env`.
