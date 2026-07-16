// Real Hedera operations. This module (and the buyer scripts) are the only
// places the operator private key is ever loaded — it never reaches Rails,
// git, logs, or any hosted service.
import {
  AccountId,
  Client,
  Hbar,
  PrivateKey,
  TokenId,
  TopicCreateTransaction,
  TopicMessageSubmitTransaction,
  TransferTransaction,
} from "@hiero-ledger/sdk";

export function buildHedera({ network, accountId, privateKey, treasury }) {
  const operatorKey = PrivateKey.fromStringECDSA(privateKey);
  const client = Client.forName(network).setOperator(accountId, operatorKey);

  return {
    network,
    treasuryConfigured: Boolean(treasury),

    async createTopic(memo) {
      const response = await new TopicCreateTransaction()
        .setTopicMemo(memo)
        .setSubmitKey(operatorKey.publicKey)
        .execute(client);
      const receipt = await response.getReceipt(client);
      return {
        topicId: receipt.topicId.toString(),
        transactionId: response.transactionId.toString(),
      };
    },

    async submitMessage(topicId, message) {
      const transaction = await new TopicMessageSubmitTransaction()
        .setTopicId(topicId)
        .setMessage(message)
        .freezeWith(client)
        .sign(operatorKey); // explicit: the topic's submitKey requires it
      const response = await transaction.execute(client);
      const receipt = await response.getReceipt(client);
      return {
        topicId,
        sequenceNumber: Number(receipt.topicSequenceNumber),
        transactionId: response.transactionId.toString(),
      };
    },

    // Batched treasury -> designers transfer, one asset per call. The tx fee
    // is paid by the operator (client); the treasury key authorizes the debit.
    async payout({ tokenId, transfers, memo }) {
      if (!treasury) throw new Error("treasury_not_configured");
      const treasuryKey = PrivateKey.fromStringECDSA(treasury.privateKey);
      const treasuryId = AccountId.fromString(treasury.accountId);
      const total = transfers.reduce((sum, t) => sum + BigInt(t.amount), 0n);

      const tx = new TransferTransaction();
      if (tokenId === "0.0.0") {
        tx.addHbarTransfer(treasuryId, Hbar.fromTinybars((-total).toString()));
        for (const t of transfers) {
          tx.addHbarTransfer(AccountId.fromString(t.accountId), Hbar.fromTinybars(t.amount));
        }
      } else {
        const token = TokenId.fromString(tokenId);
        tx.addTokenTransfer(token, treasuryId, Number(-total));
        for (const t of transfers) {
          tx.addTokenTransfer(token, AccountId.fromString(t.accountId), Number(t.amount));
        }
      }
      if (memo) tx.setTransactionMemo(memo);
      tx.freezeWith(client);
      await tx.sign(treasuryKey);
      const response = await tx.execute(client);
      await response.getReceipt(client); // throws unless SUCCESS
      return { transactionId: response.transactionId.toString() };
    },

    close() {
      client.close();
    },
  };
}
