// Real Hedera operations. This module (and the buyer scripts) are the only
// places the operator private key is ever loaded — it never reaches Rails,
// git, logs, or any hosted service.
import {
  AccountId,
  Client,
  CustomRoyaltyFee,
  Hbar,
  PrivateKey,
  TokenAirdropTransaction,
  TokenCreateTransaction,
  TokenId,
  TokenMintTransaction,
  TokenSupplyType,
  TokenType,
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

    async createHeartbeatTopic() {
      const response = await new TopicCreateTransaction()
        .setTopicMemo("printwright public liveness pwh-1")
        .setAdminKey(operatorKey.publicKey)
        .setSubmitKey(operatorKey.publicKey)
        .setAutoRenewAccountId(AccountId.fromString(accountId))
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

    // One NFT collection per designer: Hedera royalties are collection-wide,
    // so per-designer collections are what makes "royalty pays the designer"
    // true on-chain. NO fallback fee — the network rejects airdrops of
    // fallback-royalty NFTs (TOKEN_AIRDROP_WITH_FALLBACK_ROYALTY, spike-proven).
    async createLicenseCollection({ name, symbol, royaltyCollector, royaltyPercent }) {
      const royalty = new CustomRoyaltyFee()
        .setFeeCollectorAccountId(AccountId.fromString(royaltyCollector))
        .setNumerator(Math.round(royaltyPercent))
        .setDenominator(100);
      const response = await new TokenCreateTransaction()
        .setTokenName(name)
        .setTokenSymbol(symbol)
        .setTokenType(TokenType.NonFungibleUnique)
        .setSupplyType(TokenSupplyType.Infinite)
        .setTreasuryAccountId(AccountId.fromString(accountId))
        .setSupplyKey(operatorKey)
        .setCustomFees([royalty])
        .setMaxTransactionFee(new Hbar(40)) // token creation costs ~$1; the client default is too low
        .execute(client);
      const receipt = await response.getReceipt(client);
      return { tokenId: receipt.tokenId.toString(), transactionId: response.transactionId.toString() };
    },

    // Mint one license serial and airdrop it to the buyer. 0-slot buyers get
    // a PENDING airdrop they claim from their wallet; auto-assoc buyers own
    // it immediately. Returns pending:true when a claim is still required.
    async mintAndAirdrop({ tokenId, metadata, recipient }) {
      const mintResponse = await new TokenMintTransaction()
        .setTokenId(TokenId.fromString(tokenId))
        .addMetadata(Buffer.from(metadata))
        .execute(client);
      const { serials } = await mintResponse.getReceipt(client);
      const serial = Number(serials[0]);

      const airdropResponse = await new TokenAirdropTransaction()
        .addNftTransfer(TokenId.fromString(tokenId), serial, AccountId.fromString(accountId), AccountId.fromString(recipient))
        .execute(client);
      const record = await airdropResponse.getRecord(client);
      return {
        serial,
        mintTransactionId: mintResponse.transactionId.toString(),
        airdropTransactionId: airdropResponse.transactionId.toString(),
        pending: (record.newPendingAirdrops?.length ?? 0) > 0,
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
