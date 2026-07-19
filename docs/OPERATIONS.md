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

## Daily / after any incident: smoke

```bash
BUYER_ACCOUNT_ID=0.0.x BUYER_PRIVATE_KEY=0x... node scripts/smoke.mjs
```

Green = app, sidecar, facilitator, a real settle, and a mirror-confirmed cert.
A red smoke outranks every other task.

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
