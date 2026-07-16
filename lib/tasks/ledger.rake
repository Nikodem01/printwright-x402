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
end
