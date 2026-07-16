namespace :ledger do
  desc "Write missing ledger entries for already-settled purchases (idempotent)"
  task backfill: :environment do
    scope = Purchase.where(status: %w[settled delivered])
    scope.find_each do |purchase|
      next if LedgerEntry.exists?(purchase: purchase)

      LedgerEntry.record_settle!(purchase)
      puts "backfilled purchase #{purchase.id} (#{purchase.amount_base_units} #{purchase.asset})"
    end
    puts "ledger covers #{LedgerEntry.distinct.count(:purchase_id)}/#{scope.count} settled purchases"
  end

  desc "Pay designers their owed treasury-custody shares (DRY_RUN=1 to preview)"
  task payout: :environment do
    results = Ledger::PayoutRunner.call(dry_run: ENV["DRY_RUN"].present?)
    if results.empty?
      puts "nothing owed to payable designers"
    else
      results.each do |payout|
        puts "#{payout.asset}: #{payout.transfers.map { |t| "#{t[:accountId]} +#{t[:amount]}" }.join(', ')}"
        puts payout.tx_id ? "  tx: https://hashscan.io/testnet/transaction/#{payout.tx_id}" : "  (dry run — nothing sent)"
      end
    end
  end

  desc "Refund a settled, undelivered purchase on-chain (PURCHASE_ID=n)"
  task refund: :environment do
    purchase = Purchase.find(ENV.fetch("PURCHASE_ID"))
    tx_id = Ledger::Refunder.call(purchase)
    puts "refunded purchase #{purchase.id} -> #{purchase.buyer_hint}"
    puts "  tx: https://hashscan.io/testnet/transaction/#{tx_id}"
  end
end

namespace :purchases do
  desc "Reconcile stale in-flight purchases against the mirror (MINUTES=30)"
  task reap: :environment do
    results = Purchases::Reaper.call(older_than: Integer(ENV.fetch("MINUTES", "30")).minutes)
    results.each { |r| puts "purchase #{r.purchase_id}: #{r.action}" }
    puts "nothing stale" if results.empty?
  end
end
