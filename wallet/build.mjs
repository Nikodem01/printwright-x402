import { readFile, writeFile } from "node:fs/promises"
import { build } from "esbuild"

const outfile = new URL("../app/assets/javascripts/hedera_wallet.js", import.meta.url)

await build({
  entryPoints: [new URL("browser.js", import.meta.url).pathname],
  bundle: true,
  platform: "browser",
  format: "esm",
  minify: true,
  alias: {
    "@hiero-ledger/sdk": new URL("node_modules/@hiero-ledger/sdk/lib/browser.js", import.meta.url).pathname
  },
  outfile: outfile.pathname
})

// Upstream packages embed whitespace-padded ASCII art and comments. Normalize
// line endings so the generated artifact passes repository whitespace checks
// and remains byte-for-byte reproducible across builds.
const bundle = await readFile(outfile, "utf8")
await writeFile(outfile, bundle.replace(/[ \t]+$/gm, ""))
