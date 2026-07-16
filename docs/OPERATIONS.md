# Operations runbook

Money moved on-chain is never rolled back — every procedure here moves state
*forward* (deliver, pay out, refund) or marks it honestly failed. All commands
run from the app root. The sidecar must be running (started **from `sidecar/`**,
it reads `sidecar/.env` for its keys) — and restarted after any migration or
topic change.

## Daily / after any incident: smoke

```bash
BUYER_ACCOUNT_ID=0.0.x BUYER_PRIVATE_KEY=0x... node scripts/smoke.mjs
```

Green = app, sidecar, facilitator, a real settle, and a mirror-confirmed cert.
A red smoke outranks every other task.

## Designer payouts

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

Signed payments whose settle never concluded hold `max_units` capacity.

```bash
MINUTES=30 bin/rails purchases:reap
```

Per stale purchase: mirror shows the credit -> rolled forward to delivered
(cert re-anchored); no credit -> failed, capacity freed; mirror unreachable ->
skipped (never fail blind).

## Stuck certificate (license minting forever)

`no_topic_configured` retries automatically once the sidecar restarts with
`HEDERA_HCS_TOPIC_ID` set. To re-anchor manually:

```bash
bin/rails runner 'CertMintJob.perform_now(License.find_by!(cert_id: "pw-000011").id)'
```

(`perform_now`, not `perform_later` — a runner's in-process queue dies with it.)

## Key custody map

| key | lives in | used for |
|---|---|---|
| operator (`HEDERA_PRIVATE_KEY`) | `sidecar/.env` only | HCS submits, payout tx fees |
| treasury (`TREASURY_PRIVATE_KEY`) | `sidecar/.env` only | payout/refund debits |
| buyer (`BUYER_PRIVATE_KEY`) | operator's shell env | demo purchases |

The Rails process never loads a private key. Never add one to `.env`.
