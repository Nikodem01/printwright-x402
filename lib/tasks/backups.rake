namespace :backups do
  desc "Dump the primary PostgreSQL database to private S3-compatible storage"
  task database: :environment do
    puts Backups::DatabaseDump.new.call
  end
end
