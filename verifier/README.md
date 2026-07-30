# printwright-verify

Verify a Printwright proof bundle against Hedera's public mirror node without calling the
Printwright application:

```sh
# From the repository:
npx --package ./verifier printwright-verify public/widget-example.bundle.json
```

The input can be a local bundle file, an HTTPS `bundle_url` from a paid response, or `-` to read
the JSON bundle from stdin. The bundle itself names the network, HCS topic, and sequence to query.

Success means the private certificate and terms match their hashes and the resulting commitment
matches valid PWC-1 JSON at the reported immutable HCS topic position. It does not prove ownership
of the buyer account, interpret the legal terms, validate model geometry, or independently replay
settlement.

The normative JSON Schema is published at `/pwc-1.schema.json`; transport and verification rules
are documented under “PWC-1 certificate standard” on Printwright's `/docs` page.
