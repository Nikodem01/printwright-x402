class CreateRodauthBaseVerifyAccountResetPasswordVerifyLoginChangeRememberLockoutActiveSessionsOtpRecoveryCodesDisallowPasswordReuse < ActiveRecord::Migration[8.1]
  def up
    enable_extension "citext"

    # Rodauth uses the existing `designers` table as its accounts table.
    # - status drives verify_account (1=unverified, 2=verified, 3=closed); existing designers are already verified.
    # - email_address becomes citext so login/uniqueness is case-insensitive even when Rodauth writes via Sequel
    #   (bypassing the model's `normalizes`).
    # - password_digest keeps the existing bcrypt hashes (account_password_hash_column) and becomes nullable so
    #   OAuth-only accounts need no password.
    add_column :designers, :status, :integer, null: false, default: 1
    execute "UPDATE designers SET status = 2"
    change_column :designers, :email_address, :citext
    change_column_null :designers, :password_digest, true

    # Used by the account verification feature
    create_table :account_verification_keys, id: false do |t|
      t.bigint :id, primary_key: true
      t.foreign_key :designers, column: :id
      t.string :key, null: false
      t.datetime :requested_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.datetime :email_last_sent, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    # Used by the password reset feature
    create_table :account_password_reset_keys, id: false do |t|
      t.bigint :id, primary_key: true
      t.foreign_key :designers, column: :id
      t.string :key, null: false
      t.datetime :deadline, null: false
      t.datetime :email_last_sent, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    # Used by the verify login change feature
    create_table :account_login_change_keys, id: false do |t|
      t.bigint :id, primary_key: true
      t.foreign_key :designers, column: :id
      t.string :key, null: false
      t.string :login, null: false
      t.datetime :deadline, null: false
    end

    # Used by the remember me feature
    create_table :account_remember_keys, id: false do |t|
      t.bigint :id, primary_key: true
      t.foreign_key :designers, column: :id
      t.string :key, null: false
      t.datetime :deadline, null: false
    end

    # Used by the lockout feature
    create_table :account_login_failures, id: false do |t|
      t.bigint :id, primary_key: true
      t.foreign_key :designers, column: :id
      t.integer :number, null: false, default: 1
    end
    create_table :account_lockouts, id: false do |t|
      t.bigint :id, primary_key: true
      t.foreign_key :designers, column: :id
      t.string :key, null: false
      t.datetime :deadline, null: false
      t.datetime :email_last_sent
    end

    # Used by the active sessions feature
    create_table :account_active_session_keys, primary_key: [:account_id, :session_id] do |t|
      t.references :account, foreign_key: { to_table: :designers }
      t.string :session_id
      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.datetime :last_use, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    # Used by the otp feature
    create_table :account_otp_keys, id: false do |t|
      t.bigint :id, primary_key: true
      t.foreign_key :designers, column: :id
      t.string :key, null: false
      t.integer :num_failures, null: false, default: 0
      t.datetime :last_use, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    # Used by the recovery codes feature
    create_table :account_recovery_codes, primary_key: [:id, :code] do |t|
      t.bigint :id
      t.foreign_key :designers, column: :id
      t.string :code
    end

    # Used by the disallow password reuse feature
    create_table :account_previous_password_hashes do |t|
      t.references :account, foreign_key: { to_table: :designers }
      t.string :password_hash, null: false
    end

    # Used by the omniauth feature (GitHub / Google account linking)
    create_table :account_identities do |t|
      t.references :account, null: false, foreign_key: { to_table: :designers, on_delete: :cascade }
      t.string :provider, null: false
      t.string :uid, null: false
      t.index [:provider, :uid], unique: true
    end
  end

  def down
    drop_table :account_identities
    drop_table :account_previous_password_hashes
    drop_table :account_recovery_codes
    drop_table :account_otp_keys
    drop_table :account_active_session_keys
    drop_table :account_lockouts
    drop_table :account_login_failures
    drop_table :account_remember_keys
    drop_table :account_login_change_keys
    drop_table :account_password_reset_keys
    drop_table :account_verification_keys
    change_column_null :designers, :password_digest, false
    change_column :designers, :email_address, :string
    remove_column :designers, :status
  end
end
