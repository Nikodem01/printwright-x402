class LibraryAccess < ApplicationRecord
  normalizes :email_address, with: ->(email) { email.strip.downcase }

  # The nonce currently embedded in valid library cookies for this email.
  def self.current_version(email_address)
    find_or_create_by!(email_address: email_address).token_version
  end

  # Rotate the nonce so every outstanding library cookie for this email is void.
  def self.revoke!(email_address)
    where(email_address: normalize_value_for(:email_address, email_address))
      .update_all("token_version = token_version + 1")
  end
end
