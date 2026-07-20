# Printwright comprehensive review — 2026-07-20

This review covers the customer product, x402/Hedera protocol path, public repository safety, operations, and the bounty submission surface. It was performed against the current working tree, including the in-progress visual refresh and early-access capture work.

## Executive assessment

Printwright is already a substantive two-sided marketplace, not a checkout demo. Buyers can discover, evaluate, license, download, recover, and verify models without creating a mandatory account. Designers have an authenticated portfolio and operations dashboard. The x402 payment, Hedera settlement, certificate, recovery, and audit paths have unusually deep automated coverage.

The product is coherent around one deliberate identity model:

- buyers do not need a password account; a durable receipt plus an optional email magic link provides their license library;
- designers have password-backed accounts with portfolio, upload/import, identity, sales, webhook, and operator surfaces;
- wallets are payment identities, not the source of durable license access.

The review found four release-blocking engineering gaps and three launch-evidence gaps. All machine-verifiable engineering gaps are now resolved. The remaining launch evidence requires a human-controlled wallet, production infrastructure, or independent users and is itemized in the release checklist.

## Customer journey coverage

| Journey | Current product surface | Assessment |
| --- | --- | --- |
| Discover models | storefront, keyword/trigram/vector search, filters, model cards, collections/categories | Complete |
| Evaluate a model | model detail, renders, mesh metadata, print guidance, license terms, designer identity, badges | Complete |
| Buy with x402 | lazy WalletConnect browser checkout, agent SDK, MCP, chat approval, batch API; HBAR and USDC quotes | Complete; live wallet approval requires the production Reown project ID |
| Receive the product | signed receipt, private expiring file URLs, durable download grant, HashScan link | Complete |
| Recover purchases | email magic-link license library and receipt token | Complete |
| Verify rights | public certificate route, HCS mirror evidence, verifier package, PWC-1 document | Complete |
| Give print feedback | paid-holder print report and print-tested badge | Complete |
| Manage designer portfolio | signup/sign-in, models, upload, bulk import, identity, sales, webhooks | Complete |
| Marketplace operations | operator dashboard, recovery controls, immutable audit evidence, open books/chaos log | Complete |
| Legal/trust | terms, privacy, takedown, versioned license texts, seller warranties, public verification | Complete for testnet launch; counsel review remains a mainnet action |

## Architecture and correctness findings

### Strong foundations

- Rails state transitions, license caps, quote selection, idempotency, and recovery paths are backed by unit/controller/property tests.
- The server never holds a buyer spending key. Operator signing is isolated in the sidecar.
- Paid model files use private object storage and short-lived service URLs in production.
- Production enables TLS assumptions, secure cookies/HSTS, host authorization, durable queue/cache databases, SMTP delivery, and fail-closed required configuration.
- The public repo ignores `.env`, key material, captured purchases, and Rails master keys. The CI secret grep and log-hygiene checks provide additional protection.
- Hosted facilitator operation avoids shipping a second custody surface. The optional self-hosted facilitator is isolated and labeled experimental.

### Findings and disposition

1. **R1 — Current browser wallet: resolved.** Checkout now lazy-loads a deterministic local bundle built with maintained Hedera WalletConnect/AppKit packages, exposes connect/reconnect/disconnect/account state, and signs exact HBAR or HTS transfers without submitting from the browser. The demo signer is opt-in only.
2. **R2 — Non-deterministic local release gate: resolved.** Local CI uses the reviewed Brakeman policy, runs Rails and system suites from a clean database, validates seeds, restores the database, and checks log hygiene. Component suites and security audits are also explicit CI jobs.
3. **R3 — Date-fragile heartbeat test: resolved.** Snapshot time is frozen and boundary behavior is covered.
4. **R4 — Docker development contract mismatch: resolved.** Compose uses `pgvector/pgvector:pg16` and loads the sidecar's isolated environment in addition to public root configuration.
5. **R5 — Customer navigation/account affordance: resolved.** My Library is primary navigation, designers see the correct signed-in dashboard route, and wallet state is distinct from durable license recovery.
6. **R6 — Dependency advisory: narrowed.** Root, sidecar, MCP, client, verifier, spike, and optional self-host facilitator packages have no high-severity audit findings. The official browser wallet stack retains four moderate and seven low transitive crypto advisories; forced remediation would downgrade the maintained wallet package, so the high-severity gate remains enforced and the residual risk is documented.
7. **R7 — App image proof: resolved in automation.** GitHub CI now builds both Rails and sidecar production images. Docker is unavailable in the local review environment, so the first remote workflow run remains the independent container proof.

## Baseline evidence

The pre-remediation baseline produced:

- RuboCop: 292 files, no offenses.
- Bundler audit: no vulnerable gems.
- Importmap audit: no vulnerable imports.
- Brakeman with the repository exclusions and ignore file: zero warnings, three reviewed ignores.
- Rails tests: 387 runs / 10,488 assertions, one date-fragile failure, one intentional skip.
- Node tests: sidecar 25, client 10, MCP 10, verifier 7, load 2, conformance 2 — all passing.
- OctoPrint unit tests: 12 passing.
- Seed catalog: 3 designers, 36 models, 45 offers, 108 files.
- System suite after the seed run: test-harness fixture contamination before browser assertions; this is R2, not 18 independent UI failures.
- Dependency audits: clean for the root, sidecar, client, MCP, and verifier packages; the optional self-host facilitator has the upstream no-fix advisories recorded as R6.
- Docker image execution: unavailable in the review environment; CI must provide this proof.

## Final engineering evidence

- Local CI: 389 Rails tests / 10,514 assertions (one intentional skip), 18 browser tests / 173 assertions, all green.
- Checkout recovery flake: reproduced as Turbo replaying an attachment navigation, fixed with non-Turbo download links, then passed five consecutive checkout-suite seeds.
- Node: load 2, conformance 2, sidecar 25, MCP 10, client 10, verifier 7, and browser wallet 4 — all green.
- OctoPrint: 12 tests green.
- Static/security: RuboCop clean across 292 files, Bundler/Importmap clean, Brakeman zero warnings with three reviewed ignores, log hygiene and authored-source secret scan clean.
- Production build: assets precompile and dummy-secret production boot path are green; the wallet bundle is deterministic at SHA-256 `645b77a84b38f8b7d9f46d05ff49a8be6f669c3fa2e6a113be7775b12080e6de`.
- Public sandbox: live local conformance passed the catalog, 402 v2, payment-header, settlement, no-funds, non-printable-receipt, and certificate-mirror checks.
- Bounded development load run: 100 requests at concurrency 10, zero errors, 26.31 requests/second, p50 371 ms, p95 408 ms, p99 427 ms.
- Mobile Lighthouse: performance 89–91 across repeat runs, accessibility 100, best practices 100, SEO 100; CLS reached 0 after font preloading.

## Human-controlled launch evidence

These are not substitutes for engineering work and are not required to complete the local build. They remain after all automated work is green:

- create/configure a Reown project ID, approve a testnet wallet connection, and capture a real browser purchase;
- deploy with domain/DNS, object storage, SMTP, error monitoring, backups, and funded/associated Hedera accounts;
- run the production smoke/conformance/restore checks and save public HashScan evidence;
- recruit external users, capture independent feedback, record the under-five-minute demo, and submit the bounty form before the deadline.
