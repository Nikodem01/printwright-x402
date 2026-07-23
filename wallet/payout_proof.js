export function payoutMessageRequest({ network, connectedAccountId, expectedAccountId, message }) {
  if (connectedAccountId !== expectedAccountId) {
    throw new Error(`Connect the staged wallet ${expectedAccountId}; ${connectedAccountId} is connected`);
  }
  return {
    signerAccountId: `hedera:${network}:${connectedAccountId}`,
    message,
  };
}
