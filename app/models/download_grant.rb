class DownloadGrant < ApplicationRecord
  belongs_to :license

  before_validation :generate_token, on: :create
  validates :token, presence: true, uniqueness: true

  def self.issue!(license)
    create!(license: license, expires_at: 24.hours.from_now)
  end

  def usable?
    expires_at.future? && uses < max_uses
  end

  def consume!
    with_lock do
      raise ActiveRecord::RecordInvalid.new(self) unless usable?
      increment!(:uses)
    end
  end

  private

  def generate_token
    self.token ||= SecureRandom.urlsafe_base64(32)
  end
end
