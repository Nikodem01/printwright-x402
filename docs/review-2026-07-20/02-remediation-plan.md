# Granular remediation plan

Every implementation item uses a Generate → Verify → Fix loop. “Done” means its acceptance checks pass and the evidence is reflected in `03-release-checklist.md`; code existing in the tree is not sufficient by itself.

## P0 — customer and release blockers

### W1. Maintained connected-wallet checkout

- [x] Add a browser-only wallet package pinned to maintained Hedera WalletConnect and compatible Hiero SDK versions.
- [x] Bundle a deterministic, locally served browser artifact; do not add CDN/runtime code execution.
- [x] Implement connect, reconnect, disconnect, selected-account display, and network validation.
- [x] Construct exact x402 HBAR and HTS transfer transactions with the facilitator as fee payer.
- [x] Request sign-and-return only; never submit from the browser.
- [x] Encode the signed bytes into the existing `PAYMENT-SIGNATURE` envelope and reuse the existing settlement/retry state machine.
- [x] Keep the local signer only when `DEMO_WALLET_URL` is explicitly configured in development/test.
- [x] Add unit tests for quote validation, transaction amounts, asset selection, network/account guards, and header encoding.
- [x] Add controller/system coverage for configured/unconfigured wallet states without requiring a real wallet popup in CI.
- [x] Update CSP, environment examples, production requirements, deploy config, README, and operations docs.

Verify: wallet package tests and audit, Rails tests, system checkout tests, production asset precompile, no private key in browser/server config.

### W2. Deterministic comprehensive release gate

- [x] Make local Brakeman use the same reviewed exclusions/ignore file as CI.
- [x] Run system tests before seed replanting so seed verification cannot contaminate fixture state.
- [x] Cover Rails, system, fuzz/property, Node component, OctoPrint, log-hygiene, and secret checks through the local gate plus explicit CI jobs.
- [x] Keep the quick default developer gate understandable; avoid silently skipping release-critical suites.
- [x] Add a Rails production Docker image build to GitHub CI.
- [x] Record the narrow wallet dependency exception without suppressing high-severity audits elsewhere.

Verify: run the release command twice from the same working tree; both runs must finish with the same result.

### W3. Time-stable heartbeat tests

- [x] Reproduce the stale snapshot at the current date.
- [x] Freeze/derive time in the test rather than weakening production freshness rules.
- [x] Run the targeted test, then the Rails suite.

Verify: targeted snapshot passes for a fixed clock and includes stale/fresh boundary coverage.

### W4. Development/deployment contract

- [x] Replace stock Compose PostgreSQL with the pgvector image/version used in CI.
- [x] Read sidecar secrets from `sidecar/.env` while keeping Rails configuration in root `.env`.
- [x] Document setup failure modes without adding key material to the root environment.
- [x] Validate Compose configuration with a parser when Docker is unavailable locally.

Verify: rendered Compose services have pgvector and the intended env files; secret grep remains green.

## P1 — marketplace polish

### P1. Account and navigation coherence

- [x] Show “Dashboard” for an authenticated designer and “For designers” otherwise.
- [x] Promote “My library” from a footer-only recovery affordance into customer navigation.
- [x] Add connected wallet account/status to the global header without implying the wallet is the license library.
- [x] Verify header wrapping, keyboard focus, and 390/1280 layouts.

Verify: request/system assertions for guest and signed-in navigation plus responsive screenshots.

### P2. Visual/accessibility completion

- [x] Validate all current visual-refresh and early-access changes as one coherent customer surface.
- [x] Check semantic headings, labels, focus behavior, reduced motion, contrast, error announcements, empty/loading/error states, and horizontal overflow.
- [x] Run Lighthouse against the public storefront and address actionable regressions.
- [x] Capture and inspect responsive storefront/header plus system-flow evidence; the system suite covers model, checkout, library, designer, and verification states.

Verify: system suite, accessibility smoke, Lighthouse evidence, screenshot inspection.

### P3. Documentation and operational handoff

- [x] Remove stale claims that browser checkout requires the demo wallet.
- [x] Document the hosted facilitator as the recommended production mode and the browser-wallet advisory status.
- [x] Ensure environment/deploy docs distinguish public configuration from secrets.
- [x] Update bounty traceability and final verification results.
- [x] List every remaining human-only action with an exact command or observable completion condition.

Verify: documentation link/command audit and clean secret scan.

## Final acceptance gate

- [x] All Rails unit/controller/property/system tests pass.
- [x] RuboCop, Bundler audit, Importmap audit, Brakeman, log hygiene, and authored-source secret scan pass.
- [x] All Node package tests pass; high-severity audits pass with the narrow browser-wallet moderate/low exception documented.
- [x] OctoPrint tests pass.
- [x] Production assets precompile and Rails boots through the dummy-secret build path.
- [x] Rails and sidecar production image build gates are present in CI; execution awaits the next GitHub workflow run.
- [x] Seed/smoke/conformance suites pass from a clean database.
- [x] Responsive and Lighthouse evidence has been inspected.
- [x] No real `.env`, keys, purchase captures, or private strategy files are tracked.
- [x] `git diff` contains only customer app, review, and gate changes traceable to this plan; pre-existing visual/early-access work was preserved and validated.
