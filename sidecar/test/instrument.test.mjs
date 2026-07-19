import test from "node:test";
import assert from "node:assert/strict";
import { sentryOptions } from "../instrument.mjs";

test("Sentry stays off without a DSN", () => {
  assert.equal(sentryOptions({}), null);
});

test("Sentry monitoring excludes default PII and bounds trace sampling", () => {
  const options = sentryOptions({
    SENTRY_DSN: "https://public@example.invalid/1",
    SENTRY_ENVIRONMENT: "testnet",
    SENTRY_TRACES_SAMPLE_RATE: "9",
  });

  assert.equal(options.sendDefaultPii, false);
  assert.equal(options.environment, "testnet");
  assert.equal(options.tracesSampleRate, 1);
});

test("an invalid trace rate disables tracing", () => {
  assert.equal(sentryOptions({ SENTRY_DSN: "https://public@example.invalid/1",
    SENTRY_TRACES_SAMPLE_RATE: "invalid" }).tracesSampleRate, 0);
});
