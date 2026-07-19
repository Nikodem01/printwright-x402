# Printwright x402 sandbox conformance

This public runner checks a reference seller's zero-funds x402 flow without a wallet or funded
account. It validates the raw HTTP 402 response, the base64 `PAYMENT-REQUIRED` header, every
PaymentRequirements field, an identical signed retry, and the resulting sandbox receipt and
local certificate mirror. It fails if any artifact could be mistaken for a payment, printable
file, real license, HashScan proof, or paid-holder capability.

Against a local Printwright server with seeds loaded:

```bash
node conformance/suite.mjs --url http://localhost:3000
```

The successful result is JSON with `conformant: true` and the seven checks performed. The module
also exports `lintPaymentRequired()` and `runConformance()` for other test runners. This is a
seller-contract fixture, not a certification authority for arbitrary x402 services.

Run its deterministic mock-server regression with `npm run test:conformance`.
