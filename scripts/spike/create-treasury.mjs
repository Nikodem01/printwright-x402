// One-time setup: create a treasury account to receive x402 payments,
// funded by the operator (buyer) account. Prints the new account id + key —
// copy them into .env as TREASURY_ACCOUNT_ID / TREASURY_PRIVATE_KEY.
import "dotenv/config";
import {
  AccountCreateTransaction,
  Client,
  Hbar,
  PrivateKey,
} from "@hiero-ledger/sdk";

const operatorId = process.env.HEDERA_ACCOUNT_ID;
const operatorKey = PrivateKey.fromStringECDSA(process.env.HEDERA_PRIVATE_KEY);
const client = Client.forTestnet().setOperator(operatorId, operatorKey);

const treasuryKey = PrivateKey.generateECDSA();
const tx = new AccountCreateTransaction().setInitialBalance(new Hbar(1));
// SDK renamed setKey → setKeyWithoutAlias; support both.
(tx.setKeyWithoutAlias ?? tx.setKey).call(tx, treasuryKey.publicKey);

const response = await tx.execute(client);
const receipt = await response.getReceipt(client);

console.log("treasury account id:", receipt.accountId.toString());
console.log("treasury private key (hex):", treasuryKey.toStringRaw());
console.log("creation tx:", response.transactionId.toString());
client.close();
