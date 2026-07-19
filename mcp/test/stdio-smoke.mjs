// Boots the MCP server over stdio and asserts the tool surface — the same
// handshake any MCP client performs, no network or funded account needed.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import http from "node:http";

test("stdio handshake lists the tools and check_license delegates to the public API", async (t) => {
  const marketplace = http.createServer((request, response) => {
    const url = new URL(request.url, `http://${request.headers.host}`);
    if (url.pathname === "/api/v1/licenses/pw-000007/latest-version") {
      assert.equal(request.headers.authorization, "Bearer update-receipt-7");
      response.setHeader("content-type", "application/json");
      return response.end(JSON.stringify({
        cert_id: "pw-000007", version: 2,
        original_certificate_hash: "sha256:old", file_hash: "sha256:new",
        changelog: "Stronger hinge.", hcs_topic_id: "0.0.9", hcs_sequence_number: 61,
        download_url: "https://printwright.example/api/v1/licenses/pw-000007/latest-version/file",
      }));
    }
    assert.equal(url.pathname, "/api/v1/licenses/pw-000007/can");
    assert.equal(url.searchParams.get("use"), "commercial_print");
    assert.equal(url.searchParams.get("qty"), "3");
    response.setHeader("content-type", "application/json");
    response.end(JSON.stringify({
      cert_id: "pw-000007", use: "commercial_print", qty: 3,
      allowed: false, reason_code: "commercial_unit_limit",
    }));
  });
  await new Promise((resolve) => marketplace.listen(0, "127.0.0.1", resolve));

  const server = spawn(process.execPath, [ fileURLToPath(new URL("../server.mjs", import.meta.url)) ], {
    env: { ...process.env, PRINTWRIGHT_URL: `http://127.0.0.1:${marketplace.address().port}` },
    stdio: [ "pipe", "pipe", "inherit" ],
  });
  t.after(() => {
    server.kill();
    marketplace.close();
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
  assert.ok(tools.includes("check_license"), `no check_license tool in ${tools}`);
  assert.ok(tools.includes("get_latest_version"), `no get_latest_version tool in ${tools}`);

  send({ jsonrpc: "2.0", id: 3, method: "tools/call", params: {
    name: "check_license", arguments: { cert_id: "pw-000007", use: "commercial_print", qty: 3 } } });
  await waitFor(() => messages.some((m) => m.id === 3));
  const toolResult = messages.find((m) => m.id === 3).result;
  assert.notEqual(toolResult.isError, true, toolResult.content[0].text);
  const decision = JSON.parse(toolResult.content[0].text);
  assert.equal(decision.allowed, false);
  assert.equal(decision.reason_code, "commercial_unit_limit");

  send({ jsonrpc: "2.0", id: 4, method: "tools/call", params: {
    name: "get_latest_version", arguments: {
      cert_id: "pw-000007", receipt_token: "update-receipt-7",
    } } });
  await waitFor(() => messages.some((m) => m.id === 4));
  const versionResult = messages.find((m) => m.id === 4).result;
  assert.notEqual(versionResult.isError, true, versionResult.content[0].text);
  const version = JSON.parse(versionResult.content[0].text);
  assert.equal(version.version, 2);
  assert.equal(version.original_certificate_hash, "sha256:old");
  assert.equal(version.file_hash, "sha256:new");
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
