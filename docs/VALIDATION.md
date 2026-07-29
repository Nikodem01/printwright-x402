# Validation record

What has actually been exercised against Hedera testnet, and by whom. Every number here is
checkable against the public mirror node without asking Printwright for anything — the commands
are included so you can re-derive them rather than take them on trust.

Last compiled: 2026-07-29.

## The on-chain record

| | |
|---|---|
| Messages on the license topic [`0.0.9585069`](https://hashscan.io/testnet/topic/0.0.9585069) | **79** (license commitments + model-version provenance) |
| x402 settles into the treasury [`0.0.9584959`](https://hashscan.io/testnet/account/0.0.9584959) | **39** |
| Distinct paying accounts | **2** — `0.0.9067781`, `0.0.9613501` |
| Assets settled | **29 in USDC** (30.75 USDC total) · **10 in HBAR** (130.53 ℏ total) |
| Span | 2026-07-15 → 2026-07-29, across **11 separate days** |
| Designer payouts executed from treasury | **6** |

Two paying accounts, both ours: this is a record of the system working, not of demand. No
outside party has bought anything.

Re-derive it:

```bash
# every message on the license topic
curl -s "https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9585069/messages?limit=1&order=desc" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['messages'][0]['sequence_number'],'messages')"

# every successful transfer touching the treasury
curl -s "https://testnet.mirrornode.hedera.com/api/v1/transactions?account.id=0.0.9584959\
&limit=100&order=desc&transactiontype=CRYPTOTRANSFER&result=success"
```

A sample of the most recent settles, each resolvable on HashScan:

| when (UTC) | payer | amount | transaction |
|---|---|---|---|
| 2026-07-25 10:44 | `0.0.9067781` | 0.25 USDC | [`0.0.7162784@1784976230.265183795`](https://hashscan.io/testnet/transaction/0.0.7162784@1784976230.265183795) |
| 2026-07-25 10:21 | `0.0.9067781` | 0.25 USDC | [`0.0.7162784@1784974906.023503671`](https://hashscan.io/testnet/transaction/0.0.7162784@1784974906.023503671) |
| 2026-07-24 13:38 | `0.0.9613501` | 0.25 USDC | [`0.0.7162784@1784900288.288350505`](https://hashscan.io/testnet/transaction/0.0.7162784@1784900288.288350505) |
| 2026-07-22 14:11 | `0.0.9067781` | 0.25 USDC | [`0.0.7162784@1784729477.481105634`](https://hashscan.io/testnet/transaction/0.0.7162784@1784729477.481105634) |
| 2026-07-20 17:34 | `0.0.9613501` | 0.25 USDC | [`0.0.7162784@1784568837.841774991`](https://hashscan.io/testnet/transaction/0.0.7162784@1784568837.841774991) |
| 2026-07-19 11:04 | — | 11.2295 HBAR | [`0.0.7162784@1784459059.566518657`](https://hashscan.io/testnet/transaction/0.0.7162784@1784459059.566518657) |

Note the transaction payer is always `0.0.7162784`, the facilitator: buyers sign the transfer and
the facilitator sponsors the network fee. That is the x402 fee model working, visible on-chain.

## Cold-clone reproduction, 2026-07-29

Every purchase below was made from a **fresh `git clone` of this repository's `main`** into an
empty directory, following only the README: `cp .env.example .env`, `bin/setup --skip-server`,
`bin/rails db:seed`, `npm install`, `bin/dev`. Setup took 38 s; the sandbox rehearsal ran 0.7 s
later; the first real settle completed **10.8 s** after the command was typed. Every door was
driven against that clone, not against a working copy.

| Door | Settlement | Result |
|---|---|---|
| Agent — `scripts/buy.mjs` | [`…@1785294144.842761447`](https://hashscan.io/testnet/transaction/0.0.7162784@1785294144.842761447) · 13.106 ℏ | `pw-53e9de6918794f4af0afe72a`, [HCS #72](https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9585069/messages/72), 344-triangle binary STL, verifier `VERIFIED` |
| Agent — batch, `quantity: 2` | [`…@1785294596.093128610`](https://hashscan.io/testnet/transaction/0.0.7162784@1785294596.093128610) · 26.212 ℏ | one settle, two licenses (serials 3 and 4), [HCS #74](https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9585069/messages/74) and [#75](https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9585069/messages/75) |
| MCP — `buy_license` | [`…@1785294728.882241414`](https://hashscan.io/testnet/transaction/0.0.7162784@1785294728.882241414) | `pw-3f2b59a9ac1618d8a5a9aff2`; the call is refused outright without `confirm: true` |
| Human — storefront cart | [`…@1785295513.025117689`](https://hashscan.io/testnet/transaction/0.0.7162784@1785295513.025117689) · 0.20 USDC | `pw-d48075b86c8c832833c59073`, [HCS #77](https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9585069/messages/77); receipt page re-downloaded the STL with no account |
| Chat — shopkeeper approval | [`…@1785296087.326924256`](https://hashscan.io/testnet/transaction/0.0.7162784@1785296087.326924256) · 0.20 USDC | `pw-383ddfaf7c7af4fe4419d90c`; the assistant could only *propose* — the approval was re-priced and cap-checked server-side |

The durable receipt was exercised separately: the non-expiring `receipt.token` re-fetched the
file list and re-downloaded the identical 17 284-byte STL long after the original download grant
was issued, with no account and no login.

## What each door has done

| Door | Exercised by | Evidence |
|---|---|---|
| Bare HTTP agent (`scripts/buy.mjs`) | repeated real buys, most recently 2026-07-29 | saved deliverables under `purchases/<slug>/` (STL + `purchase.json` + proof bundle) |
| MCP assistant (`mcp/server.mjs`) | tool-driven purchase | `cd mcp && npm test` spawns the real server over stdio; a real `buy_license` settle is in the table above |
| Browser checkout | wallet-signed checkout | `bin/rails test:system` drives the x402 states and the receipt end to end; a real browser settle is in the table above |
| Batch API | one aggregate settle, many licenses | covered in the Rails suite and in the table above |
| Sandbox (`X-Sandbox: true`) | credential-free rehearsal | `conformance/suite.mjs` runs the whole contract against a live server in CI |

## The standing gate

Every demo-path change closes on a **real settle**, not a mock. `scripts/smoke.mjs` boots the app,
the sidecar, and the facilitator, buys a licence with real testnet value, waits for the commitment
to anchor, and then hands the delivered proof bundle to the standalone verifier CLI over stdin —
requiring a `VERIFIED` verdict before the gate goes green. A run that settles but cannot be
independently verified is a failed run.

The most recent gate run (2026-07-25) settled `0.0.7162784@1784976230.265183795`, anchored the
commitment at topic `0.0.9585069` **sequence 59**, and the verifier reported bundle integrity,
certificate schema, terms integrity, and Hedera anchoring all VERIFIED. That same proof bundle is
embedded in [`public/widget-example.html`](../public/widget-example.html), where the browser widget
re-verifies it against the live mirror from a static page.

That run is also what caught the last real defect: `terms integrity FAILED`, because the licence
text had been edited in place after publication. Self-testing that only ever passes is not
evidence; this one found something.

## Reproducibility

A fresh-clone rehearsal reached a real settlement using only the README — no source reading, no
tribal knowledge. The facilitator dependency is not a single point of failure: the self-host
fallback in [`selfhost-facilitator/`](../selfhost-facilitator/) runs the same contract behind one
environment variable, and the sandbox mode completes the whole flow with no funds at all.

## What this is not

Being straight about the limit of the above: **these are our own test buys.** Two independently
keyed Hedera accounts have paid real testnet value through the public rails on eight separate days,
which demonstrates the flow works repeatedly and is verifiable by a stranger — but it is not the
same as an outside person choosing to buy something.

Not yet done, and not claimed:

- **No independent third party has purchased on a public deployment.** The marketplace has not been
  put in front of outside buyers or designers.
- **No collected user feedback.** No interviews, no usability notes, no traction data.

That remains the weakest part of the submission, and it needs outsiders and a public URL rather
than another test run from us.
