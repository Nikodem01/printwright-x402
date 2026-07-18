// The spend cap guards a real money path: a malformed MAX_SPEND_CENTS must
// never silently disable it (Number("abc") is NaN, and `price > NaN` is
// false, which would wave every offer through). These tests drive the
// server's boot guard directly — no marketplace, no MCP handshake needed,
// since the guard runs before the server ever connects over stdio.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const SERVER = fileURLToPath(new URL("../server.mjs", import.meta.url));

function bootWith(maxSpendCents) {
  return spawnSync(process.execPath, [ SERVER ], {
    env: { ...process.env, MAX_SPEND_CENTS: maxSpendCents },
    encoding: "utf8",
    timeout: 5000,
  });
}

test("MAX_SPEND_CENTS=abc (non-numeric) refuses to boot", () => {
  const result = bootWith("abc");
  assert.notEqual(result.status, 0, `expected non-zero exit, got ${result.status}`);
  assert.match(result.stderr, /MAX_SPEND_CENTS must be a non-negative number of cents/);
  assert.match(result.stderr, /"abc"/);
});

test("MAX_SPEND_CENTS=-5 (negative) refuses to boot", () => {
  const result = bootWith("-5");
  assert.notEqual(result.status, 0, `expected non-zero exit, got ${result.status}`);
  assert.match(result.stderr, /MAX_SPEND_CENTS must be a non-negative number of cents/);
  assert.match(result.stderr, /"-5"/);
});
