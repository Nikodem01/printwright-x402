# printwright-verify

Verify a Printwright PWC-1 certificate against Hedera's public mirror node without calling the
Printwright application:

```sh
# From the repository before the npm release:
npx --package ./verifier printwright-verify pw-000058

# Registry command after release:
npx printwright-verify \
  https://testnet.mirrornode.hedera.com/api/v1/topics/0.0.9585069/messages/50
```

A Printwright `/verify/pw-NNNNNN` URL is also accepted; the CLI extracts the ID and queries the
known public HCS topic directly. Use `--topic 0.0.N` for another PWC-1 issuer/topic, `--network`
to select a network, or `--mirror` to select a compatible mirror node.

Success means the payload is valid PWC-1 JSON at the reported immutable HCS topic position and,
when an ID was supplied, that its `cert_id` matches. It does not prove ownership of the buyer
account, interpret the legal terms, validate model geometry, or independently replay settlement.

The normative JSON Schema is published at `/pwc-1.schema.json`; transport and verification rules
are documented under “PWC-1 certificate standard” on Printwright's `/docs` page.
