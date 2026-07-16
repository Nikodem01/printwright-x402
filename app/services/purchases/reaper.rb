require "net/http"

module Purchases
  # Reconciles stale in-flight purchases so they stop holding offer capacity.
  # For each pending/verified purchase older than the cutoff:
  #   - money DID move (mirror shows the credit)  -> roll forward to delivered
  #     (same funnel the controller uses), cert job enqueued;
  #   - money did NOT move                        -> fail it, freeing capacity.
  # Mirror-unreachable purchases are skipped (never fail a purchase blind).
  class Reaper
    Result = Struct.new(:purchase_id, :action, keyword_init: true)

    def self.call(older_than: 30.minutes)
      Purchase.where(status: %w[pending verified])
        .where(created_at: ..older_than.ago)
        .order(:id)
        .map { |purchase| reconcile(purchase) }
    end

    def self.reconcile(purchase)
      if (tx_id = X402::MirrorReconciler.call(purchase))
        roll_forward(purchase, tx_id)
      elsif mirror_reachable?
        purchase.update!(error_reason: "reaped_stale")
        purchase.transition_to!(purchase.pending? ? :failed_verification : :failed_settlement)
        Result.new(purchase_id: purchase.id, action: "failed_stale")
      else
        Result.new(purchase_id: purchase.id, action: "skipped_mirror_unreachable")
      end
    end

    def self.roll_forward(purchase, tx_id)
      purchase.update!(payment_tx_id: tx_id)
      purchase.transition_to!(:settled)
      license = License.allocate!(purchase)
      purchase.transition_to!(:delivered)
      CertMintJob.perform_later(license.id)
      Result.new(purchase_id: purchase.id, action: "rolled_forward")
    rescue License::SoldOut
      purchase.update!(error_reason: "sold_out_after_payment")
      Result.new(purchase_id: purchase.id, action: "settled_sold_out_refund_candidate")
    end

    # One cheap probe: if the mirror itself is down, MirrorReconciler's nil
    # means "unknown", not "no payment" — and failing on unknown loses money.
    def self.mirror_reachable?
      base = ENV.fetch("MIRROR_NODE_URL", "https://testnet.mirrornode.hedera.com")
      Net::HTTP.get_response(URI("#{base}/api/v1/network/nodes?limit=1")).code.to_i == 200
    rescue StandardError
      false
    end
  end
end
