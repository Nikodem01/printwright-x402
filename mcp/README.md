# printwright-mcp

An [MCP](https://modelcontextprotocol.io) server that exposes the [Printwright](../README.md)
marketplace — licensed 3D-printable models, paid over [x402](https://www.x402.org/) on Hedera —
to any MCP client (Claude Code, Claude Desktop, ...). It is a thin wrapper over the public REST
API: every tool call is a `fetch` to `PRINTWRIGHT_URL`, plus the x402 payment negotiation for
`buy_license`. Catalog, payment, and certificate behavior is delegated to the same
`@printwright/client` package as the command-line buyer so those consumers cannot drift. No
account with Printwright, no card — just a funded Hedera testnet account.

## Tools

- **`search_models`** — search the catalog by keywords, max price, material, supports. Returns
  id, title, license offers, and printability facts.
- **`get_model`** — full metadata for one model: description, tags, file hash, license offers
  with terms.
- **`buy_license`** — **spends real Hedera testnet funds.** Negotiates the x402 payment for a
  model's license, signs a Hedera transfer with `BUYER_PRIVATE_KEY`, and returns the file
  download URLs, license serial, certificate id, and HashScan transaction link. Requires
  `confirm: true` in the tool call — the server refuses outright without it, and separately
  refuses any offer priced above `MAX_SPEND_CENTS`.
- **`verify_certificate`** — fetches Printwright's copy of a license certificate *and* the
  on-chain HCS message from the public Hedera mirror node, and reports `match: true/false`.

## Environment variables

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `PRINTWRIGHT_URL` | no | `http://localhost:3000` | Base URL of the Printwright marketplace API. |
| `BUYER_ACCOUNT_ID` | for `buy_license` | — | Funded Hedera account that pays for licenses (e.g. `0.0.xxxxxxx`). `HEDERA_ACCOUNT_ID` is accepted as a fallback name. |
| `BUYER_PRIVATE_KEY` | for `buy_license` | — | That account's hex ECDSA private key, used locally to sign the payment — never sent anywhere but the Hedera network. `HEDERA_PRIVATE_KEY` is accepted as a fallback name. |
| `MAX_SPEND_CENTS` | no | `500` | Hard cap, in USD cents, on any single `buy_license` purchase. **Any offer priced above this is refused.** A malformed value (non-numeric or negative) makes the server refuse to start at all, printing why — this exists so a typo can never silently disable the cap. Set to `0` to refuse every priced offer (a deliberate "buying is off" setting, not a fallback). |
| `HEDERA_NETWORK` | no | `testnet` | `testnet` or `mainnet`. Selects the signing network and the USDC token id (`0.0.429274` testnet / `0.0.456858` mainnet), the same switch the rest of the project derives from. Anything other than `mainnet` is treated as testnet. |

`BUYER_ACCOUNT_ID` and `BUYER_PRIVATE_KEY` are only required to call `buy_license`;
`search_models`, `get_model`, and `verify_certificate` need none of them.

## Mount it in Claude Code / Claude Desktop

From a checkout of this repo:

```bash
cd mcp && npm install && cd ..
claude mcp add printwright \
  --env PRINTWRIGHT_URL=http://localhost:3000 \
  --env BUYER_ACCOUNT_ID=0.0.xxxxxxx \
  --env BUYER_PRIVATE_KEY=0x... \
  --env MAX_SPEND_CENTS=500 \
  -- node mcp/server.mjs
```

Then ask something like *"find a printable beaver with a hat under $3 and buy a personal
license."* The assistant will call `search_models`, then `get_model`, then ask you to confirm
before calling `buy_license` with `confirm: true`.

## Run it directly

```bash
cd mcp
npm install
PRINTWRIGHT_URL=http://localhost:3000 \
BUYER_ACCOUNT_ID=0.0.xxxxxxx \
BUYER_PRIVATE_KEY=0x... \
MAX_SPEND_CENTS=500 \
  node server.mjs
```

The server talks MCP over stdio and logs its ready line (marketplace URL, effective spend cap)
to stderr.

## npx

`package.json` declares a `printwright-mcp` bin, so `npx printwright-mcp` works as an entry
point once the runtime dependencies are installed. **This package is not published to npm
yet** — there is no `npx printwright-mcp` that fetches from the registry. Until it is
published, run it from a local checkout or tarball:

```bash
# from a checkout, in place:
cd mcp && npm install && npx printwright-mcp

# or from a packed tarball, anywhere:
cd mcp && npm pack
npm install /path/to/printwright-mcp-0.1.0.tgz   # in some scratch project
npx printwright-mcp
```

Either way, set the environment variables above before running — `claude mcp add` (above) can
pass `--env` flags directly to whichever form you use, including `-- npx printwright-mcp`.
