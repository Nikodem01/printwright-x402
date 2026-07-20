# Release and human-action checklist

This is the evidence ledger for the remediation plan. Machine-verifiable items are completed during this review. Human-controlled items stay unchecked with exact handoff steps.

## Automated release evidence

| Gate | Result | Evidence / note |
| --- | --- | --- |
| Ruby style | Pass | 292 files, zero offenses |
| Gem/import security | Pass | Bundler and Importmap report no vulnerable packages |
| Rails static analysis | Pass | Brakeman: zero warnings, three reviewed ignores |
| Rails tests | Pass | 389 runs / 10,514 assertions / zero failures / one intentional skip |
| System tests | Pass | 18 runs / 173 assertions; checkout suite also passed five consecutive seeds after the replay fix |
| Node suites | Pass | load 2, conformance 2, sidecar 25, MCP 10, client 10, verifier 7, wallet 4 |
| Node audits | Pass at high severity | all non-wallet packages clean; wallet has four moderate/seven low transitive findings in the official maintained stack |
| OctoPrint | Pass | 12 tests |
| Seed catalog | Pass | 3 designers / 36 models / 45 offers / 108 files; test DB restored afterward |
| x402 conformance | Pass | unit contract and live local sandbox runner |
| Assets / production boot | Pass | production asset precompile plus eager production boot with explicit non-secret S3 placeholders |
| Container builds | Gate implemented | Rails and sidecar builds are CI jobs; local Docker unavailable, so remote execution is outstanding |
| Accessibility / Lighthouse | Pass | storefront: performance 89–91, accessibility 100, best practices 100, SEO 100, CLS 0 |
| Secret / log hygiene | Pass | no authored-source match; real local env/key files are ignored and none are tracked |

## Human-controlled deployment

- [ ] Push the app branch and confirm every GitHub workflow job is green, especially the Rails/sidecar image builds and deterministic wallet-bundle check.
- [ ] Create a Reown project for the production origin and set the documented public project ID.
- [ ] Fund the Hedera operator/treasury accounts and associate all receiving accounts with testnet USDC.
- [ ] Provision the private object-storage bucket and backup target.
- [ ] Provision SMTP and verify password-reset, library-access, and early-access mail delivery.
- [ ] Provision Sentry (or the chosen error monitor) and trigger one controlled test event.
- [ ] Configure domain/DNS/TLS and deploy Rails plus the key-isolated HCS sidecar.
- [ ] Run migrations, seed only if a demo catalog is intended, and confirm `/up` plus the operations health snapshot.
- [ ] Execute the production smoke, x402 conformance, heartbeat, backup, and restore-rehearsal procedures in `docs/OPERATIONS.md`.

## Human-controlled bounty proof

- [ ] Connect HashPack through the production-origin WalletConnect modal.
- [ ] Complete one HBAR and one USDC testnet purchase; retain receipt, HashScan, and HCS certificate links.
- [ ] Confirm a buyer can recover the purchase through the emailed license library.
- [ ] Ask at least five target users to complete discovery-to-download without coaching; record outcomes and quotes with consent.
- [ ] Record the final uninterrupted demo using the proof chain in `01-bounty-scorecard.md` and keep it below five minutes.
- [ ] Recheck the official deadline/time zone and submit every required link before the cutoff.
