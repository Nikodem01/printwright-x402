module X402
  # After a settle timeout the transaction may still have settled on-chain.
  # Look for a successful transfer matching (payTo, amount, asset) since the
  # purchase began; return the transaction id in `0.0.x@s.n` form, or nil.
  class MirrorReconciler
    def self.call(purchase)
      requirements = purchase.requirements_json
      pay_to = requirements["payTo"]
      amount = requirements["amount"].to_i
      asset = requirements["asset"]

      url = URI("#{mirror_base}/api/v1/transactions" \
                "?account.id=#{pay_to}&timestamp=gte:#{purchase.created_at.to_i}&order=asc&limit=100")
      body = JSON.parse(Net::HTTP.get(url))

      match = body.fetch("transactions", []).find do |tx|
        tx["result"] == "SUCCESS" && credited?(tx, pay_to, amount, asset)
      end
      match && match["transaction_id"].sub("-", "@").sub("-", ".")
    rescue StandardError
      nil # mirror unavailable == not reconciled; the caller may retry later
    end

    def self.credited?(tx, pay_to, amount, asset)
      transfers =
        if asset == Requirements::HBAR_ASSET
          tx.fetch("transfers", [])
        else
          tx.fetch("token_transfers", []).select { |t| t["token_id"] == asset }
        end
      transfers.any? { |t| t["account"] == pay_to && t["amount"].to_i == amount }
    end

    def self.mirror_base
      ENV.fetch("MIRROR_NODE_URL", "https://testnet.mirrornode.hedera.com")
    end
  end
end
