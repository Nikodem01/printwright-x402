module Ledger
  # Operator-triggered on-chain refund: treasury -> buyer for the full gross,
  # memo carrying the replay key so the tx is matchable to the purchase from
  # HashScan alone. Only settled (paid, undelivered) purchases qualify — a
  # delivered purchase keeps its license, and a paid-out purchase needs a
  # clawback decision a human must make (see docs/OPERATIONS.md).
  class Refunder
    class NotRefundable < StandardError; end

    def self.call(purchase)
      raise NotRefundable, "status is #{purchase.status}, only settled refunds" unless purchase.settled?
      unless purchase.buyer_hint.to_s.match?(/\A0\.0\.\d+\z/)
        raise NotRefundable, "buyer account unknown (buyer_hint=#{purchase.buyer_hint.inspect})"
      end
      if LedgerEntry.exists?(purchase: purchase, entry_kind: "designer_payout")
        raise NotRefundable, "designer already paid out — resolve the clawback manually"
      end

      response = SidecarClient.new.payout(
        token_id: purchase.asset,
        transfers: [ { accountId: purchase.buyer_hint, amount: purchase.amount_base_units } ],
        memo: "printwright refund #{purchase.replay_key.first(32)}"
      )
      tx_id = response.fetch("transactionId")

      purchase.transaction do
        purchase.update!(refund_tx_id: tx_id)
        purchase.transition_to!(:refunded)
        LedgerEntry.create!(
          purchase: purchase, entry_kind: "refund", asset: purchase.asset,
          amount_base_units: purchase.amount_base_units, held_by: "treasury", tx_id: tx_id
        )
      end
      tx_id
    end
  end
end
