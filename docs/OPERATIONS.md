# Operations runbook

Money moved on-chain is never rolled back — every procedure here moves state
*forward* (deliver, pay out) or marks it honestly failed. All commands
run from the app root. The sidecar must be running (started **from `sidecar/`**,
it reads `sidecar/.env` for its keys) — and restarted after any migration or
topic change.

## Operator panel

The application-state procedures in this runbook—stale-purchase reconciliation,
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

Create a Reown project for the exact production origin and set its public identifier as
`WALLETCONNECT_PROJECT_ID`. A production boot refuses to start without it. This identifier is not
a signing secret; buyer approval remains inside the connected wallet. After deployment, connect
HashPack and complete the HBAR/USDC browser checks in the review release checklist.

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
health only, so retain the paid smoke check below.

### Variant: deploying behind an existing reverse proxy

The topology above assumes kamal-proxy owns 80/443. When the host already runs a web server —
another site, a company proxy — that server keeps the public ports and Printwright sits behind it.
Three things change, and nothing about the app does:

1. **kamal-proxy moves off the standard ports and off the public interface.**

   ```bash
   bin/kamal proxy boot_config set --http-port 8080 --https-port 8443 --bind-ips 127.0.0.1
   ```

2. **TLS terminates upstream**, so set `proxy.ssl: false` in `config/deploy.yml` and leave
   `forward_headers: true`. Rails keeps `assume_ssl` and `force_ssl`; the upstream proxy must send
   `X-Forwarded-Proto`, or every request becomes a redirect loop. This is the classic failure — the
   check for it is in the verification list below, not left to chance.

3. **The upstream vhost proxies to `127.0.0.1:8080`** and must forward `Host`, `X-Forwarded-Host`,
   `X-Forwarded-For`, `X-Forwarded-Proto`, and the `Upgrade`/`Connection` pair that Turbo and Action
   Cable need. Its `client_max_body_size` (or equivalent) must exceed the app's own upload cap, or
   large model uploads fail before Rails ever sees them.

Put any new proxy configuration in **new** files rather than editing the existing site's — a
separate vhost and a separate include for any shared maps or rate-limit zones. A deploy that never
edits the neighbour's files is a deploy that can be reverted by deleting files.

### Variant: Docker Compose on the host, without Kamal

Kamal drives every build through a local `docker` CLI — including `remote:` builds, where the remote
builder is still orchestrated by local `docker buildx`. On a workstation with no working Docker, no
Kamal setting helps. Building *and* running on the deployment host's own daemon sidesteps it, and is
simpler than the registry route: when the builder and the runtime are the same daemon there is
nothing to push or pull, so the registry disappears along with its failure modes.

Ship the source and build in place:

```bash
rsync -az --delete --exclude '.git/' --exclude 'node_modules/' --exclude 'tmp/' \
      --exclude 'log/' --exclude 'storage/' --exclude '.env*' ./ user@host:/opt/printwright/app/
ssh user@host 'cd /opt/printwright && docker compose build && docker compose up -d'
```

`node_modules` is deliberately excluded: the wallet bundle is prebuilt and committed, and the image
build never runs npm. `.env*` is excluded because the production env files are written separately
with `600` permissions and must never arrive by rsync.

What such a compose file has to preserve, and why each matters more than the tool used to get there:

* **Nothing binds a public interface.** Publish the app as `127.0.0.1:8080:80` and let the upstream
  proxy reach it. Docker publishes *past* the host firewall — `0.0.0.0` here would expose the app
  directly regardless of iptables rules.
* **Postgres and the signing sidecar are never published at all**, only reachable over a private
  bridge network shared with the app.
* **Hard `mem_limit` on every service.** On a small shared host this is what makes a runaway
  container die in its own cgroup instead of the kernel choosing a victim from another service.
* **Keys reach only the sidecar's `env_file`.** The Rails service's env file must contain no
  private key at all — verified after boot, see "Proving custody after a deploy".

### Variant: building on the deployment host

Kamal needs a registry to push to and pull from, even when the builder and the target are the same
machine. A `registry:2` container bound to loopback is enough:

```bash
docker run -d --restart always --name registry \
  -p 127.0.0.1:5000:5000 -v registry_data:/var/lib/registry registry:2
```

Then point `KAMAL_REGISTRY_SERVER` at `127.0.0.1:5000` and use a remote builder. Docker treats
`127.0.0.1` as an allowed insecure registry, so no daemon configuration is needed and nothing is
exposed off-box — confirm with `ss -tlnp | grep 5000` that it is bound to loopback and not `0.0.0.0`.

Building on a small shared host needs guardrails, because a build peaks far above the app's steady
memory and disk use:

```bash
# BEFORE every build — refuse to start if either is tight
df -h /                       # want several GB free beyond the image size
free -m                       # confirm swap exists and is not already in use
# AFTER every deploy
docker image prune -f
docker exec registry bin/registry garbage-collect /etc/docker/registry/config.yml
```

Never build while a co-resident service is visibly serving load. Give every Printwright container an
explicit memory limit so a runaway process is killed inside its own cgroup instead of letting the
kernel pick a victim elsewhere on the box.

### Storage quotas

Open signup plus unbounded uploads is a full disk, and on a shared host a full disk is everyone's
outage. Four settings bound it (`.env.example` documents each):

| setting | bounds |
|---|---|
| `STORAGE_BYTES_PER_DESIGNER` | total attached bytes for one account |
| `STORAGE_BYTES_GLOBAL` | total attached bytes for the whole deployment |
| `MAX_MODELS_PER_DESIGNER` | model rows per account |
| `MAX_FILES_PER_MODEL` | attachments per model |

Size `STORAGE_BYTES_GLOBAL` **below** the volume actually provisioned, so the cap is reached before
the filesystem is. Uploads over any cap are refused cleanly with a reason the designer can act on —
never a 500, never a partial write. A value that is not a plain integer is read as `0`, which
refuses every upload: a typo must never be mistaken for "unlimited". Current usage:

```bash
bin/kamal app exec 'bin/rails runner "puts Uploads::Quota.global_bytes"'
```

Pair the global cap with a host-level free-disk alert; the cap protects the app, the alert protects
the machine.

### Verifying a deploy behind a proxy

Beyond the checks above, confirm the parts the proxy can break:

```bash
# HTTPS is served and the redirect chain terminates (no loop)
curl -sSI "https://$APP_HOST/up" | head -1
curl -sSI "http://$APP_HOST/"    | grep -i location      # -> https://…, once

# HSTS survives the upstream hop
curl -sSI "https://$APP_HOST/" | grep -i strict-transport-security

# the demo signal reaches agents
curl -sSI "https://$APP_HOST/api/v1/models" | grep -i x-printwright-environment

# Postgres is NOT reachable from outside the docker network
ss -tlnp | grep 5432 || echo "correct: not published to a host port"
```

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

**Deployments with no object-storage provider** set `STORAGE_BACKEND=disk` and `STORAGE_DISK_ROOT`
to a mounted, size-capped volume. Active Storage then uses the `production_disk` service, signed
URLs still expire on the same TTL, and the `S3_*` values become unnecessary — boot requires
`STORAGE_DISK_ROOT` instead. The selection is explicit on purpose: falling back to local disk
because a credential happened to be missing is how paid files end up somewhere nobody is backing
up. Two consequences worth stating plainly:

* **Files are only as durable as one disk.** Losing the host loses the models. Acceptable for a
  demo; not for anything a designer would be upset to lose.
* **The disk is now a shared failure mode** with everything else on the machine. Pair this with the
  storage quotas above and a host free-disk alert — the quota protects the app, the alert protects
  the box.

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
zero local license rows, then removed only the named scratch database and temporary dump.

On **2026-07-31** the same rehearsal ran against the real production database on the deployment
host, restoring into a scratch database inside the `db` container. Every count matched the source —
37 models, 47 offers, 1 licence, 1 purchase — and the `cert_id` of the genuine paid purchase
(`pw-66dcbd6945e60adb41b0a722`) survived the round trip, which is the assertion that actually
matters: a dump that restores rows but loses the licence a buyer paid for is not a backup. Only the
scratch database and the staged dump were removed afterwards.

That rehearsal also caught the reason backups had never worked in this image: `pg_dump` was
version 15 against a version 16 server and refused outright. Nothing surfaces that failure until
the nightly job runs, so **rehearse a restore on any new deployment before trusting the schedule** —
a backup job that has never produced a restorable file is not a backup job.

### A backup on the same disk is not a backup

When object storage is a local volume on the deployment host rather than a remote provider, the
nightly job is protecting against exactly one failure — someone deleting rows. It protects against
none of the ones that actually destroy a deployment: a full disk, a corrupted filesystem, a
terminated instance, or a host that will not boot. Everything is on the same disk, so everything
dies together.

Treat that setup as a rehearsal aid, not as durability, and pull a dump off the box regularly. One
command, run from a workstation, writing to local disk and never leaving anything behind on the
server:

```bash
ssh "$DEPLOY_USER@$DEPLOY_HOST" \
  'docker exec printwright_x402-db pg_dump -U printwright_x402 --format=custom printwright_x402_production' \
  > "printwright-$(date +%Y%m%dT%H%M%S).dump"
```

Verify what landed before trusting it — a zero-byte file is the usual failure:

```bash
ls -lh printwright-*.dump && pg_restore --list printwright-*.dump | head
```

The restore rehearsal above is what proves the file is usable. A dump nobody has ever restored is a
hypothesis, not a backup.

## Designer payouts

Every purchase settles to the treasury (destination-charge model): we are
merchant-of-record and capture the platform fee atomically at settle. A
designer's share is **queued automatically after delivery** by
`DesignerPayoutJob`, which runs `Ledger::PayoutRunner` scoped to that
checkout — one summed transfer per designer per asset, memo `printwright payout
purchase-<id>` (single) or `printwright payout batch-<id>` (batch).

Designers manage the destination in **Payouts**, not Profile. Creating or changing
one requires enrolled two-factor authentication, a password used within five minutes,
and a WalletConnect `hedera_signMessage` proof checked against the account's current
on-chain key by the sidecar. Rails then runs the USDC receivability preflight. A first
destination activates immediately after both checks; a replacement keeps the existing
destination active during a visible 24-hour safety hold and requires an explicit final
activation. The verified account email is notified when a change is requested, proved,
activated, or cancelled. **Cancel pending change** is the self-service recovery path;
an owner who did not initiate it should also change their password and revoke other
sessions. No step changes purchases, licenses, certificates, receipts, or downloads.

The rake task / admin panel below is the **backstop**: it sweeps everything
still owed — designers who weren't payout-verified at checkout (their share
waits until they verify) and any post-delivery payout that failed or exhausted retries.

Panel: `/admin` → **Preview designer payouts** or **Run designer payouts**. The run button has
an explicit confirmation and the same database advisory lock as the command.

```bash
DRY_RUN=1 bin/rails ledger:payout   # preview per-designer totals per asset
bin/rails ledger:payout             # one batched tx per asset, Mirror Node links printed
```

- Only designers with an active payout destination are paid. New destinations must
  pass signed control proof and the mirror receivability check; grandfathered active
  destinations remain eligible until changed and are prompted to add signed proof.
  Everyone else stays owed (visible via `LedgerEntry.owed`).
- Runs are serialized by a session-level DB advisory lock shared with immediate jobs
  and account closure. Each asset's ledger rows commit before the next asset begins,
  so a later asset failure cannot erase the record for an earlier successful transfer.
- `PayoutAttempt` is mutable operational state, not the financial ledger. Definitely
  pre-submit failures (connection/setup unavailable) receive bounded automatic retries
  and eventually expose a designer retry against the same owed rows and current verified
  destination. A sidecar `hedera_error`, lost response, reset, timeout, invalid response,
  or post-transfer ledger failure is instead `reconciliation_required` and is excluded
  from every immediate and backstop payout run.
- Reconciliation-required attempts appear in `/admin` under **Payout attention** with
  their checkout reference, safe error code, amount, time, and known transaction id.
  The memo names the run — `printwright payout <checkout-ref>` (immediate) or
  `printwright designer payout <date>` (backstop). Check the treasury account on
  Mirror Node for that exact transaction or memo. **Never retry while the result is
  ambiguous**: first establish whether the transfer reached consensus, then record the
  existing transaction in the ledger or return the attempt to a safe not-submitted
  state through a reviewed operator repair. Preserve the attempt and evidence in the
  incident record; do not edit an immutable ledger row.

## Designer account closure

Account closure is intentionally blocked while the designer has an owed ledger
share or a non-sandbox purchase in `pending`, `verified`, or `settled`. Do not
bypass either check: closing at that point could remove the payout destination
before earned funds are sent or let an already-reserved payment settle after the
seller has left.

- For owed earnings, verify the active destination in **Payouts**, preview the
  payout, run the payout procedure above, and confirm that no `LedgerEntry.owed`
  rows remain for the designer.
- For an in-flight purchase, use `/admin` to reconcile it. Reap a genuinely stale
  signed payment with `MINUTES=0 bin/rails purchases:reap`; never mark it failed
  without the mirror-node check performed by the reconciler.
- Ask the designer to reload the closure review after the blocker is resolved.
  There is no operator force-close path.

A successful closure deletes unpurchased listings and private seller integrations,
retires every listing with purchase history, removes it from discovery and all new
checkout paths, revokes sessions, and scrubs email, bio, identity, and payout data.
The studio display name and purchase-backed records remain as the minimum historical
attribution needed by receipts and certificates. Existing licenses, certified
bundles, grants, downloads, receipts, certificate verification, and version rights
continue to work. Queued webhook jobs whose seller delivery was deleted safely no-op.

## Capacity overrun (defensive backstop)

All sales are final and availability is decided under the offer row lock
*before* a payment is accepted, so a paid purchase always has a reserved
unit. If license allocation ever still hits the cap
(`error_reason=capacity_overrun`, reaper action
`capacity_overrun_operator_review`), capacity accounting is broken — treat
it as a bug, not a workflow. The buyer's settled payment and its
transaction id are preserved on the purchase; investigate the offer's
`capacity_used` versus `max_units`, fix the accounting, and re-run
**Reconcile #…** so the purchase rolls forward to delivered. A settled
purchase is always deliverable once the unit exists; nothing here returns
money.

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
node scripts/fund-buyer.mjs              # default: 200 ℏ + 20 USDC
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
docs.hedera.com), mirror node, and Mirror Node links. `MIRROR_NODE_URL` still
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
| HCS message (the opaque commitment) | about $0.0008 plus payload-byte extras | every purchase |
| token transfer (settle leg) | $0.0001–0.001 | every purchase (facilitator pays) |
| token association (first USDC payout) | $0.05 | once per designer, paid by the operator |
| account create (demo/testing) | $0.05 | rare |
| HCS topic create | $0.01 | once |

## Key custody map

| key | lives in | used for |
|---|---|---|
| operator (`HEDERA_PRIVATE_KEY`) | `sidecar/.env` only | HCS submits, payout tx fees |
| treasury (`TREASURY_PRIVATE_KEY`) | `sidecar/.env` only | payout debits |
| buyer (`BUYER_PRIVATE_KEY`) | operator's shell env | demo purchases |

The Rails process never loads a private key. Never add one to `.env`.

### Proving custody after a deploy

The map above is a claim; these are the checks that make it a fact. Run all of them before calling
a deploy done, and treat any hit as a stop.

```bash
# 1. Not in the Rails container's environment
bin/kamal app exec 'env' | grep -E 'HEDERA_PRIVATE_KEY|TREASURY_' && echo FAIL || echo ok

# 2. Not baked into an image layer or its build history
docker history --no-trunc "$KAMAL_APP_IMAGE" | grep -iE 'PRIVATE_KEY|\.env' && echo FAIL || echo ok

# 3. File permissions on anything holding a key
stat -c '%a %n' sidecar/.env .env      # both must be 600

# 4. Never committed, in either repo
git log --all --oneline -- .env sidecar/.env    # must print nothing

# 5. Not in logs or error payloads — throw once from a signing path and read the result
bin/kamal app logs --lines 500 | grep -iE 'PRIVATE_KEY|302e0201' && echo FAIL || echo ok
```

Sentry runs with PII off; confirm one deliberately failed signing operation produces an event whose
payload contains no key material before trusting the integration.

### Key rotation

A key used for a public demo should be treated as spent when the demo ends — especially one that
doubles as a development key. Rotation checklist:

1. Create a fresh key for the operator account, or a fresh account, in the Hedera portal.
2. Update `sidecar/.env` on the host and `bin/kamal env push`; restart the sidecar accessory only —
   Rails never held the key and does not need a restart.
3. Submit one certificate and confirm it appears on the topic under the new key.
4. Retire the old key on the account so the previous value stops being a credential.
5. Re-run the custody checks above.

Rotate immediately, not on schedule, if a key ever appears in a diff, a log line, an image layer, or
a screenshot.

## Complete teardown

Removing Printwright from a shared host must leave every co-resident service untouched. In order:

```bash
# 1. Application and accessories
bin/kamal app remove
bin/kamal accessory remove db
bin/kamal accessory remove sidecar
bin/kamal proxy remove

# 2. The build/registry apparatus, if the host was also the builder
docker rm -f registry && docker volume rm registry_data
docker image prune -a -f
docker builder prune -a -f

# 3. Data volumes — irreversible, so take a dump off-box first
bin/kamal accessory exec db 'pg_dump …' > backup.sql   # see the backup section
docker volume rm printwright_x402_postgres

# 4. The upstream proxy vhost and its TLS certificate
sudo rm -f /etc/nginx/sites-enabled/<app> /etc/nginx/sites-available/<app>
sudo rm -f /etc/nginx/conf.d/<app>-*.conf
sudo nginx -t && sudo systemctl reload nginx
sudo certbot delete --cert-name "$APP_HOST"
```

What deliberately survives: the Docker engine itself, the host firewall rules, and every file
belonging to another service. Because all proxy configuration went into *new* files, step 4 is a
delete rather than an edit — there is no shared file to restore. Verify the neighbour is still
serving before and after every step, and finish by rotating the Hedera keys per the checklist above.
