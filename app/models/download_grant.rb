class DownloadGrant < ApplicationRecord
  belongs_to :license

  # A grant is a bearer URL for a file the buyer has already paid for and may
  # legally copy, so it rations nothing. A per-grant download ceiling used to
  # sit here; it protected nothing, because the receipt capability re-mints a
  # grant on demand and never expires — it only added a way for a half-finished
  # multi-file download to fail. Request cost is bounded where it is actually
  # incurred, by the rate limit on Api::V1::FilesController.
  #
  # The lifetime survives for one narrow reason: a grant URL that leaks into a
  # log, a chat transcript, or an agent's scratch file stops being a public
  # mirror of the file after a month. A buyer who comes back later re-mints one
  # from their receipt, which is why a month is generous rather than load-bearing.
  LIFETIME = 30.days

  before_validation :generate_token, on: :create
  validates :token, presence: true, uniqueness: true

  def self.issue!(license)
    create!(license: license, expires_at: LIFETIME.from_now)
  end

  # One live grant per license is enough: a second token for a file the holder
  # already reaches adds a row without adding access.
  def self.for(license)
    license.download_grants.detect(&:usable?) || issue!(license)
  end

  def usable?
    expires_at.future?
  end

  def consume!
    increment!(:uses)
  end

  private

  def generate_token
    self.token ||= SecureRandom.urlsafe_base64(32)
  end
end
