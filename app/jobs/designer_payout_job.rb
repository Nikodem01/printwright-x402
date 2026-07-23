# Pays a completed checkout's designers their share immediately after delivery
# (destination-charge model): the buyer settled to the treasury, so we transfer
# the owed share out. Reuses Ledger::PayoutRunner scoped to this checkout's
# purchases — it groups by asset + designer and sums, so a multi-model checkout
# from one designer is a single payment. Designers whose payout account isn't
# verified are skipped (their share stays owed for the admin backstop).
#
# Idempotent: the `owed` scope + the unique [purchase_id, entry_kind] index make
# a second payout for the same purchase impossible. retry_on covers only the
# pre-settle transport failure (Unavailable), which is raised before money moves.
class DesignerPayoutJob < ApplicationJob
  queue_as :default
  retry_on SidecarClient::Unavailable, wait: :polynomially_longer, attempts: 10 do |job, _error|
    arguments = job.arguments.first
    PayoutAttempt.exhaust!(ref: arguments["ref"] || arguments.fetch(:ref))
  end

  def perform(purchase_ids:, ref:)
    Ledger::PayoutRunner.call(purchase_ids: purchase_ids, ref: ref, automatic_retry: true)
  end
end
