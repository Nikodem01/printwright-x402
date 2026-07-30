# printwright-verify

Verify a local Printwright proof bundle against Hedera's public mirror node without calling the
Printwright application:

```sh
# From the repository:
npx --package ./verifier printwright-verify public/widget-example.bundle.json
```

The input can also be an HTTPS `bundle_url` from a paid response, or `-` to read the JSON bundle
from stdin. URL input fetches that untrusted bundle once; file/stdin input calls only the public
Mirror Node. The verifier derives the Mirror Node URL from the bundle's network, topic, and
sequence rather than trusting its supplied URL or verdict.

Success means the private certificate and terms satisfy PWC-1, match their hashes, and produce the
same commitment as the valid opaque envelope at the reported immutable HCS topic position. It
does not prove ownership of the buyer account, interpret the legal terms, validate model geometry,
or independently replay settlement.

The normative JSON Schema is published at `/pwc-1.schema.json`; transport and verification rules
are documented under “PWC-1 certificate standard” on Printwright's `/docs` page.
