import assert from "node:assert/strict";
import { createServer } from "node:http";
import test from "node:test";
import { parseArgs, runLoadSanity } from "./load-sanity.mjs";

test("runs the requested bounded burst and reports latency and status counts", async (t) => {
  const server = createServer((_request, response) => {
    response.setHeader("content-type", "application/json");
    response.end('{"models":[]}');
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(() => server.close());

  const address = server.address();
  const options = parseArgs([
    "--url", `http://127.0.0.1:${address.port}`,
    "--requests", "12", "--concurrency", "4", "--timeout-ms", "1000"
  ]);
  const result = await runLoadSanity(options);

  assert.equal(result.requests, 12);
  assert.equal(result.warmup_status, 200);
  assert.equal(result.concurrency, 4);
  assert.deepEqual(result.statuses, { 200: 12 });
  assert.equal(result.errors.length, 0);
  assert.ok(result.latency_ms.p95 >= result.latency_ms.min);
  assert.ok(result.requests_per_second > 0);
});

test("refuses unsafe or unbounded targets", () => {
  assert.throws(() => parseArgs([ "--url", "http://example.com" ]), /must use https/);
  assert.throws(() => parseArgs([ "--url", "https://example.com", "--path", "https://other.example" ]), /relative path/);
  assert.throws(() => parseArgs([ "--url", "https://example.com", "--concurrency", "201" ]), /between 1 and 200/);
  assert.throws(() => parseArgs([ "--url", "https://example.com", "--requests", "10001" ]), /between 1 and 10000/);
});
