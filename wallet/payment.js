import {
  AccountId,
  Client,
  Hbar,
  TokenId,
  TransactionId,
  TransferTransaction,
} from "@hiero-ledger/sdk";

const NETWORKS = new Set(["testnet", "mainnet"]);

export function selectAcceptedPayment(paymentRequired, network) {
  assertNetwork(network);
  if (paymentRequired?.x402Version !== 2 || !paymentRequired.resource) {
    throw new TypeError("wallet requires an x402 v2 payment challenge");
  }

  const accepted = paymentRequired.accepts?.find((candidate) =>
    candidate?.scheme === "exact" && candidate.network === `hedera:${network}`
  );
  if (!accepted) throw new TypeError(`quote does not support Hedera ${network}`);

  const amount = parseAmount(accepted.amount);
  AccountId.fromString(accepted.payTo);
  AccountId.fromString(accepted.extra?.feePayer);
  if (accepted.asset !== "0.0.0") TokenId.fromString(accepted.asset);

  return { accepted, amount };
}

export function buildPaymentTransaction({ accepted, amount, accountId, network }) {
  assertNetwork(network);
  if (accepted?.network !== `hedera:${network}` || accepted.scheme !== "exact") {
    throw new TypeError("accepted payment does not match the connected network");
  }

  const buyer = AccountId.fromString(accountId);
  const payTo = AccountId.fromString(accepted.payTo);
  const feePayer = AccountId.fromString(accepted.extra?.feePayer);
  const units = amount ?? parseAmount(accepted.amount);
  const transaction = new TransferTransaction();

  if (accepted.asset === "0.0.0") {
    transaction.addHbarTransfer(buyer, Hbar.fromTinybars((-units).toString()));
    transaction.addHbarTransfer(payTo, Hbar.fromTinybars(units.toString()));
  } else {
    const token = TokenId.fromString(accepted.asset);
    transaction.addTokenTransfer(token, buyer, -units);
    transaction.addTokenTransfer(token, payTo, units);
  }

  transaction.setTransactionId(TransactionId.generate(feePayer));
  const client = Client.forName(network);
  try {
    return transaction.freezeWith(client);
  } finally {
    client.close();
  }
}

export function paymentSignatureHeaders(paymentRequired, accepted, signedTransaction) {
  if (!paymentRequired?.accepts?.some((candidate) => canonical(candidate) === canonical(accepted))) {
    throw new TypeError("signed payment selection is not present in the server challenge");
  }
  const bytes = signedTransaction instanceof Uint8Array
    ? signedTransaction
    : signedTransaction.toBytes();
  const payload = {
    x402Version: paymentRequired.x402Version,
    resource: paymentRequired.resource,
    accepted,
    payload: { transaction: bytesToBase64(bytes) },
  };
  return { "PAYMENT-SIGNATURE": utf8ToBase64(JSON.stringify(payload)) };
}

function assertNetwork(network) {
  if (!NETWORKS.has(network)) throw new TypeError("wallet network must be testnet or mainnet");
}

function parseAmount(value) {
  let amount;
  try {
    amount = BigInt(value);
  } catch {
    throw new TypeError("payment amount must be a positive integer");
  }
  if (amount <= 0n) throw new TypeError("payment amount must be a positive integer");
  return amount;
}

function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function bytesToBase64(bytes) {
  if (typeof Buffer !== "undefined") return Buffer.from(bytes).toString("base64");
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
  }
  return btoa(binary);
}

function utf8ToBase64(value) {
  return bytesToBase64(new TextEncoder().encode(value));
}
