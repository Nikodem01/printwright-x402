class AddCertSaltToLicenses < ActiveRecord::Migration[8.0]
  def change
    # Off-chain salt for the certificate commitment: only SHA-256(cert || salt)
    # is published to HCS, so the public topic reveals no designer, buyer,
    # model, or per-model count. Legacy full-cert licenses keep salt NULL.
    add_column :licenses, :cert_salt, :string
  end
end
