// Real Hedera operations. This module (and the buyer scripts) are the only
// places the operator private key is ever loaded — it never reaches Rails,
// git, logs, or any hosted service.
import {
  Client,
  PrivateKey,
  TopicCreateTransaction,
  TopicMessageSubmitTransaction,
} from "@hiero-ledger/sdk";

export function buildHedera({ network, accountId, privateKey }) {
  const operatorKey = PrivateKey.fromStringECDSA(privateKey);
  const client = Client.forName(network).setOperator(accountId, operatorKey);

  return {
    network,

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

    close() {
      client.close();
    },
  };
}
