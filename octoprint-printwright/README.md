# Printwright for OctoPrint

Printwright licenses each queued print over x402. On OctoPrint's real `PrintStarted` event the
plugin pauses the printer, performs the payment negotiation on a background thread, and resumes
only after Printwright returns a public license certificate. If validation, signing, settlement,
or certificate creation fails, the job stays paused.

The event record includes only `name`, storage `path`, `origin`, and optional file `size`; it
deliberately omits OctoPrint user/owner fields. Payment logs contain public certificate and ledger
URLs, never challenges, signatures, API keys, or signer output.

Install into the same Python environment as OctoPrint:

```sh
python -m pip install ./octoprint-printwright
```

Install and configure `hcli` separately on the OctoPrint host. The plugin passes the exact raw
`PAYMENT-REQUIRED` challenge to `hcli x402 sign`; hcli's configured account alias or KMS reference
signs it without placing a private key in OctoPrint. See the
[hiero-cli quick start](https://www.npmjs.com/package/@hiero-ledger/hiero-cli#quick-start).

As of 2026-07-19, the x402 command exists on hiero-cli `main` but is not included in the published
1.2.0 tarball. Until the next release, pin the audited upstream commit that introduced this flow:

```sh
npm install -g github:hiero-ledger/hiero-cli#1439634c99f4c89d5d32b8cf5a15198186711b17
hcli x402 sign --help
```

## Configure

Open OctoPrint **Settings → Printwright** and set:

- the Printwright marketplace URL and the model ID assigned to this printer queue;
- `testnet` or `mainnet`, the exact accepted asset ID, and a base-unit spend ceiling;
- the hcli executable and an hcli payer alias or key reference—not a private key;
- **Enable** only after a dry rehearsal.

The plugin always requests a `commercial_unit` license. It rejects a challenge whose resource,
network, asset, or amount differs from configuration. A zero spend ceiling disables real spending.
For reference, native USDC is `0.0.429274` on testnet and `0.0.456858` on mainnet; its six decimal
places mean a 50-cent ceiling is `500000` base units.

Sandbox mode is labeled simulation: no funds move and no real license or printable file is issued.
The plugin refuses to use it with anything except OctoPrint's `VIRTUAL` printer.

Equivalent `config.yaml`:

```yaml
plugins:
  printwright:
    enabled: true
    base_url: "https://printwright.example"
    model_id: 48
    license_kind: "commercial_unit"
    network: "testnet"
    asset: "0.0.429274"
    max_amount: 500000
    hcli_path: "hcli"
    signer_from: "farm-payer"
    sandbox: false
```

## Virtual-printer acceptance

Run the isolated virtual-printer acceptance rehearsal from the repository root:

```sh
OCTOPRINT_BIN=/path/to/octoprint scripts/octoprint_spike_smoke.sh
```

The script boots a temporary loopback instance with a generated one-run API key, connects
`VIRTUAL`, uploads a harmless G-code fixture, starts it, and requires a
`PRINTWRIGHT_JOB_STARTED` record. It deletes its temporary OctoPrint home on exit.

To exercise the whole labeled sandbox flow against a running local Printwright app:

```sh
PRINTWRIGHT_SPIKE_BASE_URL=http://127.0.0.1:3000 \
PRINTWRIGHT_SPIKE_MODEL_ID=48 \
PRINTWRIGHT_SPIKE_SANDBOX=true \
PRINTWRIGHT_SPIKE_EXPECT_LICENSED=true \
OCTOPRINT_BIN=/path/to/octoprint \
scripts/octoprint_spike_smoke.sh
```

The required proof is a `PRINTWRIGHT_LICENSED` record containing a `sandbox-pw-*` certificate and
local sandbox receipt links. It is honest virtual-printer evidence, not a testnet settlement or a
physical print claim.
