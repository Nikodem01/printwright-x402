// Entry point: load env (repo root .env first, then a local sidecar/.env),
// wire the real SDK in, listen on localhost only.
import { config } from "dotenv";
import { fileURLToPath } from "node:url";
import { buildHedera } from "./hedera.mjs";
import { createApp } from "./app.mjs";

config({ path: fileURLToPath(new URL("../.env", import.meta.url)) });
config();

for (const name of ["HEDERA_ACCOUNT_ID", "HEDERA_PRIVATE_KEY", "SIDECAR_TOKEN"]) {
  if (!process.env[name]) throw new Error(`${name} is required`);
}

const PORT = Number(process.env.SIDECAR_PORT || 4021);
const HOST = process.env.SIDECAR_HOST || "127.0.0.1"; // 0.0.0.0 inside docker
const hedera = buildHedera({
  network: process.env.HEDERA_NETWORK || "testnet",
  accountId: process.env.HEDERA_ACCOUNT_ID,
  privateKey: process.env.HEDERA_PRIVATE_KEY,
  // Optional: enables POST /payout (treasury -> designer transfers).
  treasury: process.env.TREASURY_ACCOUNT_ID && process.env.TREASURY_PRIVATE_KEY
    ? { accountId: process.env.TREASURY_ACCOUNT_ID, privateKey: process.env.TREASURY_PRIVATE_KEY }
    : null,
});

createApp({
  hedera,
  token: process.env.SIDECAR_TOKEN,
  topicId: () => process.env.HEDERA_HCS_TOPIC_ID,
  heartbeatTopicId: () => process.env.HEDERA_HEARTBEAT_TOPIC_ID,
}).listen(PORT, HOST, () => {
  console.log(`hcs sidecar on ${HOST}:${PORT} (network: ${hedera.network})`);
});
