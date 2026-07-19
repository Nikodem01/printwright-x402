class ProfileVerification < ApplicationRecord
  belongs_to :designer

  enum :status, %w[pending verified failed expired revoked].index_by(&:itself), default: "pending"
  validates :profile_url, :host, :challenge_token, :expires_at, presence: true
end
