require "sequel/core"

class RodauthMain < Rodauth::Rails::Auth
  configure do
    # ==> Features
    enable :create_account, :verify_account, :verify_account_grace_period,
      :login, :logout, :remember,
      :reset_password, :change_password, :change_login, :verify_login_change,
      :close_account, :lockout, :active_sessions,
      :otp, :recovery_codes, :disallow_password_reuse,
      :confirm_password, :password_grace_period, :omniauth

    # ==> General
    # Initialize Sequel and have it reuse Active Record's database connection.
    db Sequel.postgres(extensions: :activerecord_connection, keep_reference: false)
    # Avoid DB query that checks accounts table schema at boot time.
    convert_token_id_to_integer? { Designer.columns_hash["id"].type == :integer }

    # The account table is the existing `designers` table; legacy bcrypt digests
    # in `password_digest` keep working (account_password_hash_column).
    accounts_table :designers
    login_column :email_address
    account_password_hash_column :password_digest
    account_status_column :status

    # Specify the controller used for view rendering, CSRF, and callbacks.
    rails_controller { RodauthController }

    # Make built-in page titles accessible in your views via an instance variable.
    title_instance_variable :@page_title

    # Set password when creating account instead of when verifying.
    verify_account_set_password? false

    # Single email + single password field (matches the existing storefront UX).
    require_login_confirmation? false
    require_password_confirmation? false

    login_param "email"
    login_label "Email address"

    # Redirect back to originally requested location after authentication.
    login_return_to_requested_location? true
    two_factor_auth_return_to_requested_location? true

    # ==> Emails
    # Deliver via Action Mailer, after the DB transaction commits.
    send_email do |email|
      db.after_commit { email.deliver_later }
    end

    # ==> Password strength (S1) — length + zxcvbn score + Have I Been Pwned check.
    password_minimum_length 10
    password_maximum_bytes 72
    password_meets_requirements? do |password|
      next false unless super(password)

      result = PasswordStrength.check(password)
      next true if result.ok?

      set_password_requirement_error_message(result.code, result.message)
      false
    end

    # ==> Sessions (S5) — server-side, revocable, with idle + absolute deadlines.
    session_inactivity_deadline 24 * 60 * 60      # 24h idle
    session_lifetime_deadline   14 * 24 * 60 * 60 # 14d absolute

    # ==> Lockout (S4) — throttle credential stuffing per account.
    max_invalid_logins 10

    # ==> Operator reauth (S3) — money moves require a recent password entry.
    # The grace also covers the just-completed login, so an operator acting right
    # after signing in isn't prompted twice; it lapses 5 minutes later.
    password_grace_period 5 * 60
    confirm_password_redirect do
      requested = remove_session_value(confirm_password_redirect_session_key)
      if requested&.start_with?("/designer/payout_destination", "/designer/payout_attempts")
        "/designer/payouts#payout-destination"
      else
        "/admin"
      end
    end

    # ==> Remember (U5) — opt-in "keep me signed in", not automatic.
    after_login { remember_login if param_or_nil("remember") }
    extend_remember_deadline? true
    remember_deadline_interval Hash[days: 30]

    # ==> Custom signup fields — designers need a display name (+ optional bio).
    # Keep accepting the legacy payout id parameter as an unverified value for
    # older clients; the current signup UI moves secure activation to Payouts.
    before_create_account do
      display_name = param("display_name").to_s.strip
      throw_error_status(422, "display_name", "must be present") if display_name.empty?
      account[:display_name] = display_name
      account[:bio] = param("bio").presence
      account[:hedera_account_id] = param("hedera_account_id").presence
      # Rodauth writes via Sequel, which doesn't populate ActiveRecord timestamps.
      account[:created_at] = account[:updated_at] = Time.current
    end

    # ==> Close account (U2/GDPR). Keep the minimum attribution row and every
    # purchase-backed model so buyer licenses/HCS proof stay valid. The service
    # retires purchase-backed listings, removes unpurchased work and private
    # integrations, and refuses to strand a payment or unpaid earnings.
    delete_account_on_close? false
    before_close_account do
      unless param("understand") == "1"
        throw_error_reason(
          :closure_not_acknowledged, 422, "closure",
          "Confirm that you understand the permanent listing, payout, and buyer-rights effects."
        )
      end

      begin
        Designers::AccountClosure.prepare!(Designer.find(account_id))
      rescue Designers::AccountClosure::Error => error
        message = case error.code
        when :outstanding_earnings
          "Your account still has earnings owed from treasury. Resolve the payout in Payouts before closing."
        when :purchase_in_progress
          "A real-money purchase is still being verified, settled, or delivered. Try again after it completes or is resolved."
        else
          error.message
        end
        throw_error_reason(error.code, 422, "closure", message)
      end
    end
    after_close_account do
      db[:account_identities].where(account_id: account_id).delete
      db[:designers].where(id: account_id).update(
        email_address: "closed-#{account_id}@printwright.invalid",
        password_digest: nil,
        bio: nil,
        specialty: nil,
        location: nil,
        profile_links: "[]",
        featured_model_id: nil,
        admin: false,
        verified: false,
        identity_verified_at: nil,
        verified_profile_url: nil,
        hedera_account_id: nil,
        payout_account_verified_at: nil,
        payout_pending_account_id: nil,
        payout_challenge: nil,
        payout_challenge_digest: nil,
        payout_challenge_expires_at: nil,
        payout_change_requested_at: nil,
        payout_proof_verified_at: nil,
        payout_hold_until: nil,
        payout_account_control_verified_at: nil,
        updated_at: Time.current
      )
    end

    # ==> Redirects
    logout_redirect "/"
    verify_account_redirect { login_redirect }
    verify_account_email_sent_redirect { "/designer" }
    verify_account_email_recently_sent_redirect { "/designer" }
    reset_password_redirect { login_path }
    login_redirect { "/designer" }
    create_account_redirect { "/designer" }

    # ==> Deadlines
    verify_account_grace_period 2.days.to_i
    reset_password_deadline_interval Hash[hours: 6]
    verify_login_change_deadline_interval Hash[days: 2]

    # ==> Social login (U3). Providers are always registered so the callback
    # routes exist (and tests can mock them); the login/signup buttons only show
    # when credentials are configured (see _omniauth partial). GitHub and Google
    # verify email ownership, so rodauth-omniauth links by email to an existing
    # account or creates a fresh, already-verified one.
    pw_config = Rails.configuration.x.printwright
    omniauth_provider :github, pw_config.github_client_id.to_s, pw_config.github_client_secret.to_s,
      scope: "user:email"
    omniauth_provider :google_oauth2, pw_config.google_client_id.to_s, pw_config.google_client_secret.to_s

    before_omniauth_create_account do
      account[:display_name] = omniauth_info["name"].presence || omniauth_email.split("@").first
      account[:status] = 2 # provider-verified email → skip our own verification
      account[:created_at] = account[:updated_at] = Time.current
    end
  end
end
