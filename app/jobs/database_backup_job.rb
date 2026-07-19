class DatabaseBackupJob < ApplicationJob
  queue_as :background

  def perform
    key = Backups::DatabaseDump.new.call
    Rails.logger.info("database backup stored key=#{key}")
  end
end
