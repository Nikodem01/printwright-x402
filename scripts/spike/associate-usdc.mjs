// One-time setup: associate the buyer account with testnet USDC (0.0.429274)
// so it can receive tokens from the Circle faucet and pay USDC offers.
import "dotenv/config";
import { Client, PrivateKey, TokenAssociateTransaction } from "@hiero-ledger/sdk";

const USDC = "0.0.429274";
const accountId = process.env.HEDERA_ACCOUNT_ID;
const key = PrivateKey.fromStringECDSA(process.env.HEDERA_PRIVATE_KEY);
const client = Client.forTestnet().setOperator(accountId, key);

const mirror = `https://testnet.mirrornode.hedera.com/api/v1/accounts/${accountId}/tokens?token.id=${USDC}`;
const existing = await (await fetch(mirror)).json();
if (existing.tokens?.length) {
  console.log(`${accountId} already associated with ${USDC}`);
} else {
  const response = await new TokenAssociateTransaction()
    .setAccountId(accountId)
    .setTokenIds([USDC])
    .execute(client);
  const receipt = await response.getReceipt(client);
  console.log(`associated ${accountId} with ${USDC}: ${receipt.status.toString()}`);
  console.log("tx:", response.transactionId.toString());
}
client.close();
