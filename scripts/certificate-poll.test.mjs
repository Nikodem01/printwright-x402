import assert from "node:assert/strict";
import test from "node:test";
import { PrintwrightError } from "@printwright/client";
import { waitForCertificate } from "./certificate-poll.mjs";

test("certificate polling survives a transient Mirror Node fetch failure", async () => {
  const outcomes = [
    new PrintwrightError("mirror fetch failed"),
    { status: "anchored", match: true },
  ];
  let waits = 0;

  const result = await waitForCertificate({
    certId: "pw-test",
    verify: async () => {
      const outcome = outcomes.shift();
      if (outcome instanceof Error) throw outcome;
      return outcome;
    },
    attempts: 3,
    delay: async () => {},
    onWait: () => waits++,
  });

  assert.equal(result.status, "anchored");
  assert.equal(waits, 1);
  assert.equal(outcomes.length, 0);
});

test("certificate polling returns a still-minting bundle after the bounded window", async () => {
  let calls = 0;
  const result = await waitForCertificate({
    certId: "pw-test",
    verify: async () => {
      calls++;
      return { status: "minting", match: null };
    },
    attempts: 3,
    delay: async () => {},
  });

  assert.equal(result.status, "minting");
  assert.equal(calls, 3);
});

test("certificate polling does not hide a non-retryable verification error", async () => {
  let calls = 0;

  await assert.rejects(
    waitForCertificate({
      certId: "pw-test",
      verify: async () => {
        calls++;
        throw new PrintwrightError("bad bundle", { status: 422 });
      },
      attempts: 3,
      delay: async () => {},
    }),
    /bad bundle/
  );
  assert.equal(calls, 1);
});
