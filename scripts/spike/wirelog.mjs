// Shared wire logger: append JSONL entries + mirror a compact line to stdout.
// Everything logged here travels over the wire in the clear (or ends up public
// on-chain), so it is safe to commit — private keys never pass through HTTP.
import { appendFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const LOG_DIR = join(dirname(fileURLToPath(import.meta.url)), "wire-log");
mkdirSync(LOG_DIR, { recursive: true });

export function wireLog(file, entry) {
  const record = { ts: new Date().toISOString(), ...entry };
  appendFileSync(join(LOG_DIR, file), JSON.stringify(record) + "\n");
  const summary = entry.note ?? `${entry.method ?? ""} ${entry.path ?? entry.url ?? ""} → ${entry.status ?? ""}`;
  console.log(`[wire:${file.replace(".jsonl", "")}] ${summary}`);
}
