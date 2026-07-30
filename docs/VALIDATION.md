# Validation record

What has actually been exercised against Hedera testnet, and by whom. The on-chain figures below
are a dated snapshot; the linked Mirror Node records remain independently fetchable.

Last compiled: 2026-07-30.

## The on-chain record

Snapshot after transaction `0.0.7162784@1785411775.692726241`:

| | |
|---|---|
| Historical shared topic [`0.0.9585069`](https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9585069) | **82 messages**: 55 legacy full-certificate messages, 1 deprecated `pwc-1` envelope, 24 current opaque commitments, and 2 `pwv-1` model-version events |
| Incoming x402 test settles to treasury [`0.0.9584959`](https://testnet.mirrornode.hedera.com/api/v1/accounts/0.0.9584959) | **53** |
| Internal paying accounts | **2** — `0.0.9067781`, `0.0.9613501` |
| Assets settled | **39 in USDC** (38.70 USDC total) · **14 in HBAR** (163.19564756 ℏ total) |
| Span | 2026-07-15 → 2026-07-30, across **12 separate UTC days** |
| Designer payouts executed from treasury | **6** (plus one separately labeled refund) |

Both paying accounts are ours. This is a record of repeated system tests, not demand or
third-party adoption. The topic breakdown also matters: messages 1–56 include the superseded
pre-commitment design. Claims that current licence writes are opaque refer only to the current
writer and are directly visible from sequence 58 onward.

Re-derive the two public streams:

```bash
curl -s "https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9585069/messages?limit=100&order=asc"

curl -s "https://testnet.mirrornode.hedera.com/api/v1/transactions?account.id=0.0.9584959\
&limit=100&order=asc&transactiontype=CRYPTOTRANSFER&result=success"
```

The transaction query contains incoming test purchases, outgoing designer payouts, and the
labeled refund. The settlement figures above count only transactions where the treasury's HBAR
or testnet USDC (`0.0.429274`) balance increases.

A sample of directly checked records:

| demonstrated behavior | evidence |
|---|---|
| 2.50 USDC x402 settle | [`0.0.7162784@1785074352.536547527`](https://testnet.mirrornode.hedera.com/api/v1/transactions/0.0.7162784-1785074352-536547527) |
| resulting current-format commitment | [HCS #60](https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9585069/messages/60) |
| one 2.60 USDC batch settle, two commitments | [settlement](https://testnet.mirrornode.hedera.com/api/v1/transactions/0.0.7162784-1785074684-046610464) · [HCS #61](https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9585069/messages/61) · [HCS #62](https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9585069/messages/62) |
| separate USDC designer payout | [`0.0.9067781@1784242883.124267302`](https://testnet.mirrornode.hedera.com/api/v1/transactions/0.0.9067781-1784242883-124267302) |
| separate model-version provenance | [HCS #70](https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9585069/messages/70) |

The x402 settlement transaction payer is `0.0.7162784`, the hosted facilitator. Buyers authorize
the value transfer; the facilitator adds its fee-payer signature and submits it.

## Cold-clone reproduction, 2026-07-30

The audit used an isolated clone and an empty PostgreSQL database. Following the README took
3 seconds to clone, 40 seconds for `bin/setup --skip-server` (including the initial seed),
37 seconds for the explicit idempotent `bin/rails db:seed`, 14 seconds for the root npm install,
and 18 seconds for the sidecar npm install. The sandbox rehearsal completed in about 1 second.
Clone start to the first real purchase was **195 seconds**; that purchase command itself took
**15 seconds**.

A new HCS topic was created exactly as the README directs:
[`0.0.9841379`](https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9841379). Every door below
was then driven against that isolated clone:

| Door | Settlement | Result |
|---|---|---|
| Agent — `scripts/buy.mjs` | [0.90 USDC](https://testnet.mirrornode.hedera.com/api/v1/transactions/0.0.7162784-1785409009-328510354) | `pw-377e5ccb22f37ccb87ad631f`, [HCS #2](https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9841379/messages/2), 17,284-byte/344-triangle STL, standalone verifier `VERIFIED` |
| Agent — batch, `quantity: 2` | [one 0.50 USDC settle](https://testnet.mirrornode.hedera.com/api/v1/transactions/0.0.7162784-1785409151-337309777) | two licences and two commitments: [HCS #3](https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9841379/messages/3), [HCS #4](https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9841379/messages/4) |
| MCP — `buy_license` | [0.90 USDC](https://testnet.mirrornode.hedera.com/api/v1/transactions/0.0.7162784-1785409226-615173835) | `pw-6de09d52d24f2bdd7b52120c`, [HCS #5](https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9841379/messages/5); the server refuses without `confirm: true` |
| Human — storefront cart | [0.90 USDC](https://testnet.mirrornode.hedera.com/api/v1/transactions/0.0.7162784-1785410098-745866509) | `pw-3bd03707185f54e1c9b50637`, [HCS #7](https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9841379/messages/7); browser receipt and re-download worked |
| Chat — local shopkeeper + approval | [0.90 USDC](https://testnet.mirrornode.hedera.com/api/v1/transactions/0.0.7162784-1785410796-543945129) | `pw-1f4d5b412c5bf6cdbb5b0de9`, [HCS #9](https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9841379/messages/9); search, proposal, separate approval, receipt, and download worked without a model-provider key |
| Post-audit paid-response check | [0.25 USDC](https://testnet.mirrornode.hedera.com/api/v1/transactions/0.0.7162784-1785411775-692726241) | `pw-e6cef5c9cc22310df1b84169`, [HCS #10](https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9841379/messages/10); exact transaction URL resolved and the standalone verifier returned `VERIFIED` |

The durable receipt capability re-fetched the file list and re-downloaded the exact same
17,284-byte STL (`sha256:9faad93d155e27f3c7fa8b7b875999865b7e48d03dc986e51d066b5b9a6b0ce3`)
without an account or login. That real re-download happened in the same audit session, before the
original 30-day grant expired; automated tests separately time-travel past grant expiry.

## What each door has done

| Door | Executed evidence |
|---|---|
| Bare HTTP agent (`scripts/buy.mjs`) | real settle, file download, OpenSCAD render, mesh checks, proof-bundle verification, and receipt re-download |
| MCP assistant (`mcp/server.mjs`) | stdio initialize/tool-list, real `buy_license`, `check_license`, and certificate verification |
| Browser checkout | real browser search, cart, approval, settlement, receipt, file download, and receipt re-download |
| Shopkeeper chat | real browser search, bounded proposal, separate approval, settlement, receipt, and file download |
| Batch API | one aggregate real settlement producing two licences and two HCS commitments |
| Sandbox (`X-Sandbox: true`) | live conformance suite with no buyer credentials or Hedera write |

## The standing smoke gate

`scripts/smoke.mjs` checks the app, sidecar, and facilitator, makes a real testnet purchase, waits
for the commitment, and requires the standalone verifier CLI to report `VERIFIED`. This gate is
not a claim that every edit has run a paid settle; it is the command used for release/demo
validation when funded credentials are available.

The portable sample in [`public/widget-example.html`](../public/widget-example.html) is the proof
bundle for HCS sequence 59. Both the standalone verifier and browser widget recompute it against
the live Mirror Node. An earlier smoke run caught a real terms-integrity failure after licence
text had been edited in place; that was fixed rather than relabeled as success.

## Reproducibility limits

The cold run used the documented prerequisites already installed on the host and a pre-funded
internal testnet account. No private key entered the Rails process. The public repository does not
provide funds, and a stranger must create/fund their own testnet buyer exactly as the README says.
The hosted facilitator has a separately runnable self-host fallback; that reduces provider
dependence but does not remove dependence on Hedera or public network access.

## What this is not

These are our own test buys. Two internally controlled Hedera accounts have paid real testnet
value on 12 UTC days. That demonstrates repeatability under our control, not outside demand or
independent user validation.

Not done and not claimed:

- **No independent third party has purchased on a public deployment.**
- **No collected user feedback.** No interviews, usability notes, or traction data.

External validation remains the weakest part of the submission.
