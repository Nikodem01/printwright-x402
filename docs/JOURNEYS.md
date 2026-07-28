# Printwright system map

[![Printwright interactive system map](journey-map-preview.png)](journey-map.html)

**[Open the interactive map](journey-map.html)** and choose one of four product
outcomes. Inactive nodes fade so the shared core and each outcome's real
asynchronous continuation remain visible.

Printwright is an agent-buyable marketplace for licensed 3D-printable models.
API, MCP, storefront, and cart converge on one licensing and
payment core. Creators publish original work and receive accountable payouts.
Hedera moves money and timestamps privacy-preserving proof that anyone can
independently verify.

## Shared purchase invariant

```text
entry mode → catalog → x402 quote → buyer signs locally → facilitator submits
           → buyer CryptoTransfer → settled purchase + local 90/10 ledger
           → licence + private files/grant + receipt + certificate/proof bundle
                                               └─ async job → sidecar → HCS commitment
```

After settlement, delivery allocates the licence and issues the private
certificate, download grant, receipt, and proof bundle without waiting for HCS.
The anchor job is queued only after the purchase is marked delivered. A
temporary sidecar or HCS failure leaves the proof bundle `minting`; it does not
block or undo paid delivery. A batch uses one aggregate payment, then creates
one licence, proof bundle, and asynchronous HCS commitment per item.

## Four outcomes

| Outcome | Complete selected path |
|---|---|
| Discover and license a model | API, MCP, storefront, or cart → shared purchase core → paid licence/access → private proof → asynchronous opaque HCS commitment |
| Publish and version a model | Original review → catalog, with no Hedera write; deliverable later version → covered owner access + asynchronous sidecar submission → `pwv-1` HCS event |
| Turn a sale into designer payout | Buyer settlement → local split ledger → paid delivery → payout runner → signing sidecar → separate treasury-to-designer CryptoTransfer; the successful transfer ID is recorded locally |
| Verify a licence independently | Buyer-disclosed bundle → local JCS/SHA-256 recomputation → exact topic/sequence GET from Mirror Node → exact commitment comparison |

Receipts, fresh download grants, and covered model updates are continuations of
private ownership/access inside the delivered licence. They are not another
purchase journey and do not add a Hedera write.

## Hedera operations stay distinct

| Product event | Hedera operation | Signing/read boundary |
|---|---|---|
| Buyer payment | HBAR or USDC `CryptoTransfer` to treasury | Buyer signs locally; facilitator verifies, fee-pays, and submits |
| Designer payout | Separate HBAR or USDC `CryptoTransfer` from treasury | Signing sidecar uses the platform treasury/operator keys |
| Licence commitment | HCS topic-message write containing only an opaque commitment envelope | Retry/backfill job uses the signing sidecar after delivery |
| Model-version provenance | Separate HCS topic-message write containing a `pwv-1` version event | Only a validated later version uses the signing sidecar |
| Public verification | Exact Mirror Node topic/sequence GET plus local recomputation | Public read only; Mirror Node never writes |

The 90/10 sales ledger is local application bookkeeping, not a Hedera ledger
operation. The current HCS licence writer never publishes the private
certificate, nonce, buyer account, designer wallet, model identity, or sale
count; it publishes only the opaque commitment envelope.

## Read the map

- Grey lines are application calls and local work.
- Dashed grey lines are asynchronous jobs that continue after their prerequisite.
- Solid green lines write value or provenance to Hedera.
- Dashed green lines are public Mirror Node reads.
- The overview is intentionally static. Choose an outcome to animate only that path.
- Moving dots then show direction; the underlying line style still identifies the operation.
- Select any node for its concise responsibility and code boundary.

## Public testnet evidence

- Current treasury settlement and resulting licence anchor: [2.50 USDC CryptoTransfer](https://testnet.mirrornode.hedera.com/api/v1/transactions/0.0.7162784-1785074352-536547527) → [opaque HCS commitment #60](https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9585069/messages/60)
- One wallet-approval batch: [2.60 USDC CryptoTransfer](https://testnet.mirrornode.hedera.com/api/v1/transactions/0.0.7162784-1785074684-046610464) → [HCS #61](https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9585069/messages/61) and [HCS #62](https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9585069/messages/62)
- Designer payouts: [grouped HBAR payout](https://testnet.mirrornode.hedera.com/api/v1/transactions/0.0.9067781-1784242876-183891625) and [USDC payout](https://testnet.mirrornode.hedera.com/api/v1/transactions/0.0.9067781-1784242883-124267302)
- Model provenance: [`pwv-1` HCS message #70](https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9585069/messages/70)
- Independent-verification anchor: [opaque HCS commitment #59](https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9585069/messages/59)

The shared testnet topic is
[`0.0.9585069`](https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9585069).
