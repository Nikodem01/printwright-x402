// Certificate anchoring is asynchronous and deliberately never gates delivery,
// so a purchase can finish while the certificate is still minting. In that
// window the anchor coordinates do not exist yet — `hedera` carries only a
// status — and reading them straight out printed `undefined` at two of the
// three proof links the README tells a buyer to expect. Report the pending
// state instead, and name the command that picks the anchor up.
export function proofLines(cert, { baseUrl, certId }) {
  const hedera = cert?.hedera;

  if (hedera?.mirror_url) {
    return [
      `   HCS topic:   ${hedera.sandbox ? `${hedera.topic_id} (LOCAL SANDBOX ONLY)` : hedera.mirror_url.replace(/\/messages\/\d+$/, "")}`,
      `   Mirror node: ${hedera.mirror_url}`,
      `   Commitment:  ${cert.commitment ?? "(pending)"}`,
    ];
  }

  // The verifier CLI takes a URL as well as a file, and the certificates
  // endpoint is keyed by cert_id, so this one command works unchanged the
  // moment the anchor lands — no need to re-download anything by hand.
  return [
    `   HCS topic:   pending — the certificate is still minting (status: ${cert?.status ?? "unknown"})`,
    `   Mirror node: pending — the anchor appears once minting completes`,
    `   Re-run:      node verifier/cli.js ${baseUrl}/api/v1/certificates/${certId}`,
    `                (fetches the bundle live, so it verifies as soon as it anchors)`,
  ];
}
