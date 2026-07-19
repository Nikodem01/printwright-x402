#!/usr/bin/env node
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";

export async function runConformance({ baseUrl = "http://localhost:3000", fetchImpl = globalThis.fetch } = {}) {
  const base = baseUrl.replace(/\/$/, "");
  const checks = [];

  const catalog = await getJson(fetchImpl, `${base}/api/v1/models?q=cable%20clip`);
  const model = catalog.models?.find((candidate) =>
    candidate.license_offers?.some((offer) => offer.kind === "personal"));
  assert(model, "catalog has no model with a personal offer");
  checks.push("catalog discovery");

  const resourceUrl = `${base}/api/v1/models/${model.id}/download?license=personal`;
  const probe = await fetchImpl(resourceUrl, { headers: { accept: "application/json", "X-Sandbox": "true" } });
  assert(probe.status === 402, `unsigned sandbox probe returned ${probe.status}, expected 402`);
  assert(probe.headers.get("x-printwright-sandbox") === "true", "402 is missing X-Printwright-Sandbox: true");
  const paymentRequired = await probe.json();
  checks.push("HTTP 402 challenge");

  const lintErrors = lintPaymentRequired({
    resourceUrl, body: paymentRequired, encodedHeader: probe.headers.get("payment-required"),
  });
  assert(lintErrors.length === 0, `PaymentRequired is non-conformant: ${lintErrors.join("; ")}`);
  checks.push("PaymentRequired v2 body/header contract");

  const accepted = paymentRequired.accepts[0];
  const payment = {
    x402Version: 2,
    resource: paymentRequired.resource,
    accepted,
    payload: { transaction: `sandbox:${randomUUID()}` },
  };
  const paid = await fetchImpl(resourceUrl, {
    headers: {
      accept: "application/json",
      "X-Sandbox": "true",
      "PAYMENT-SIGNATURE": Buffer.from(JSON.stringify(payment)).toString("base64"),
    },
  });
  assert(paid.ok, `signed sandbox retry returned ${paid.status}`);
  assert(paid.headers.get("x-printwright-sandbox") === "true", "delivery is missing X-Printwright-Sandbox: true");
  const paymentResponse = decodeHeader(paid.headers.get("payment-response"), "PAYMENT-RESPONSE");
  assert(paymentResponse.success === true && paymentResponse.sandbox === true,
    "PAYMENT-RESPONSE is not an explicit successful sandbox settlement");
  assert(paid.headers.get("x-payment-response") === paid.headers.get("payment-response"),
    "X-PAYMENT-RESPONSE compatibility header differs");
  const delivery = await paid.json();
  checks.push("signed retry + settlement response");

  assert(delivery.sandbox === true, "delivery is not labeled sandbox");
  assert(/no (hedera )?funds move|simulation only/i.test(delivery.warning || ""), "delivery warning is ambiguous");
  assert(/^sandbox-pw-/.test(delivery.license?.cert_id || ""), "certificate id lacks sandbox namespace");
  assert(delivery.hashscan_url === null, "sandbox delivery claims a HashScan transaction");
  assert(!delivery.model_updates && !delivery.print_feedback, "sandbox delivery leaked a paid-holder capability");
  assert(delivery.files?.length > 0 && delivery.files.every((file) =>
    file.kind === "sandbox_receipt" && file.sandbox !== false), "sandbox delivery exposed printable files");
  checks.push("no funds/license/geometry claims");

  const receipt = await fetchImpl(delivery.files[0].url);
  assert(receipt.ok, `sandbox receipt returned ${receipt.status}`);
  assert(/sandbox/i.test(await receipt.text()), "downloaded receipt is not labeled sandbox");
  checks.push("non-printable receipt");

  const certificate = await getJson(fetchImpl,
    `${base}/api/v1/certificates/${encodeURIComponent(delivery.license.cert_id)}`);
  assert(certificate.status === "sandbox" && certificate.certificate?.sandbox === true,
    "certificate lookup is not labeled sandbox");
  assert(certificate.hcs?.sandbox === true, "certificate pretends its local topic is HCS");
  const mirror = await getJson(fetchImpl, new URL(certificate.hcs.mirror_url, `${base}/`).toString());
  const mirrored = JSON.parse(Buffer.from(mirror.message, "base64").toString("utf8"));
  assert(canonical(mirrored) === canonical(certificate.certificate), "local mirror message differs from certificate");
  checks.push("local certificate mirror equality");

  return { conformant: true, seller: base, cert_id: delivery.license.cert_id, checks };
}

export function lintPaymentRequired({ resourceUrl, body, encodedHeader }) {
  const errors = [];
  let header;
  try {
    header = JSON.parse(Buffer.from(encodedHeader || "", "base64").toString("utf8"));
  } catch {
    errors.push("PAYMENT-REQUIRED is not base64 JSON");
  }
  if (body?.x402Version !== 2) errors.push("x402Version must be 2");
  if (body?.sandbox !== true || !/no (hedera )?funds move|simulation only/i.test(body?.warning || "")) {
    errors.push("challenge must be unmistakably labeled as a zero-funds sandbox");
  }
  if (body?.resource?.url !== resourceUrl) errors.push("resource.url must equal the requested URL");
  if (!Array.isArray(body?.accepts) || body.accepts.length === 0) {
    errors.push("accepts must contain at least one requirement");
  } else {
    body.accepts.forEach((requirement, index) => {
      const prefix = `accepts[${index}]`;
      if (requirement.scheme !== "exact") errors.push(`${prefix}.scheme must be exact`);
      if (requirement.network !== "hedera:sandbox") errors.push(`${prefix}.network must be hedera:sandbox`);
      if (!/^[1-9]\d*$/.test(requirement.amount || "")) errors.push(`${prefix}.amount must be a positive decimal string`);
      if (requirement.asset !== "sandbox:credit") errors.push(`${prefix}.asset must be sandbox:credit`);
      if (requirement.payTo !== "sandbox:designer") errors.push(`${prefix}.payTo must be sandbox:designer`);
      if (!Number.isInteger(requirement.maxTimeoutSeconds) || requirement.maxTimeoutSeconds <= 0) {
        errors.push(`${prefix}.maxTimeoutSeconds must be a positive integer`);
      }
      if (requirement.extra?.feePayer !== "sandbox:facilitator" || requirement.extra?.sandbox !== true) {
        errors.push(`${prefix}.extra must identify the sandbox facilitator`);
      }
    });
  }
  if (header && canonical(header) !== canonical(body)) errors.push("PAYMENT-REQUIRED header and body differ");
  return errors;
}

async function getJson(fetchImpl, url) {
  const response = await fetchImpl(url, { headers: { accept: "application/json" } });
  assert(response.ok, `GET ${url} returned ${response.status}`);
  return response.json();
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function decodeHeader(value, name) {
  try {
    return JSON.parse(Buffer.from(value || "", "base64").toString("utf8"));
  } catch {
    throw new Error(`${name} is not base64 JSON`);
  }
}

function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const index = process.argv.indexOf("--url");
  const baseUrl = index >= 0 ? process.argv[index + 1] : process.env.PRINTWRIGHT_URL;
  try {
    console.log(JSON.stringify(await runConformance({ baseUrl }), null, 2));
  } catch (error) {
    console.error(`x402 sandbox conformance failed: ${error.message}`);
    process.exitCode = 1;
  }
}
