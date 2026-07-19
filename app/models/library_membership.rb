class LibraryMembership < ApplicationRecord
  TOKEN_PURPOSE = "license-library-access".freeze
  TOKEN_LIFETIME = 30.minutes

  belongs_to :license

  normalizes :email_address, with: ->(email) { email.strip.downcase }

  validates :email_address, presence: true, length: { maximum: 254 },
    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :license_id, uniqueness: true
  validate :paid_delivered_license

  def self.access_token(email_address)
    verifier.generate(
      normalize_value_for(:email_address, email_address),
      purpose: TOKEN_PURPOSE,
      expires_in: TOKEN_LIFETIME
    )
  end

  def self.email_from_token(token)
    verifier.verify(token, purpose: TOKEN_PURPOSE)
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    nil
  end

  def self.verifier
    Rails.application.message_verifier("license-library")
  end
  private_class_method :verifier

  private

  def paid_delivered_license
    return if license&.purchase&.delivered? && !license.purchase.sandbox?

    errors.add(:license, "must be a delivered paid license")
  end
end
