// Boots the MCP server over stdio and asserts the tool surface — the same
// handshake any MCP client performs, no network or funded account needed.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

test("stdio handshake lists the printwright tools", async () => {
  const server = spawn(process.execPath, [ fileURLToPath(new URL("../server.mjs", import.meta.url)) ], {
    stdio: [ "pipe", "pipe", "inherit" ],
  });
  const send = (msg) => server.stdin.write(JSON.stringify(msg) + "\n");

  const messages = [];
  let buffer = "";
  server.stdout.on("data", (chunk) => {
    buffer += chunk;
    let idx;
    while ((idx = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, idx).trim();
      buffer = buffer.slice(idx + 1);
      if (line) messages.push(JSON.parse(line));
    }
  });

  send({ jsonrpc: "2.0", id: 1, method: "initialize", params: {
    protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "smoke", version: "0" } } });
  await waitFor(() => messages.some((m) => m.id === 1));
  send({ jsonrpc: "2.0", method: "notifications/initialized" });
  send({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });
  await waitFor(() => messages.some((m) => m.id === 2));

  const tools = messages.find((m) => m.id === 2).result.tools.map((t) => t.name).sort();
  assert.ok(tools.length >= 3, `expected several tools, got ${tools}`);
  assert.ok(tools.some((t) => /buy/.test(t)), `no buy tool in ${tools}`);
  assert.ok(tools.some((t) => /search|list/.test(t)), `no search tool in ${tools}`);

  server.kill();
});

function waitFor(ready, ms = 5000) {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    const tick = () => {
      if (ready()) return resolve();
      if (Date.now() - start > ms) return reject(new Error("timed out"));
      setTimeout(tick, 50);
    };
    tick();
  });
}
