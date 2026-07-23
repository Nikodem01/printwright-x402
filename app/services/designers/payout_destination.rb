require "digest"

module Designers
  # Stages payout destinations without changing the active payout route. A new
  # wallet must sign a single-use challenge and pass the same USDC receivability
  # check used by payouts. Replacements then wait through a visible recovery
  # window before the designer can activate them.
  class PayoutDestination
    CHALLENGE_TTL = 15.minutes
    REPLACEMENT_HOLD = 24.hours

    class Error < StandardError
      attr_reader :code

      def initialize(code)
        @code = code
        super(code.to_s.humanize)
      end
    end

    def self.request!(designer:, account_id:)
      account_id = account_id.to_s.strip
      raise Error, :invalid_account unless account_id.match?(/\A0\.0\.\d+\z/)
      if designer.payout_account_verified? &&
          designer.payout_account_control_verified_at.present? &&
          designer.hedera_account_id == account_id
        raise Error, :already_active
      end

      challenge = challenge_for(designer, account_id)
      designer.with_lock do
        raise Error, :account_closed if designer.account_closed?

        designer.update!(
          payout_pending_account_id: account_id,
          payout_challenge: challenge,
          payout_challenge_digest: digest(challenge),
          payout_challenge_expires_at: CHALLENGE_TTL.from_now,
          payout_change_requested_at: Time.current,
          payout_proof_verified_at: nil,
          payout_hold_until: nil
        )
      end
      PayoutDestinationMailer.change_requested(designer, account_id).deliver_later
      Designers::Notifier.record_later(designer: designer, kind: "payout_destination_staged",
        payload: { hedera_account_id: account_id })
      challenge
    end

    def self.verify!(designer:, message:, signature_map:, client: SidecarClient.new,
      account_check: PayoutAccountCheck)
      message = message.to_s
      account_id = nil
      expected_digest = nil

      designer.with_lock do
        raise Error, :account_closed if designer.account_closed?

        validate_challenge!(designer, message)
        account_id = designer.payout_pending_account_id
        expected_digest = designer.payout_challenge_digest
      end

      proof = client.verify_payout_proof(
        account_id: account_id, message: message, signature_map: signature_map.to_s
      )
      raise Error, :invalid_signature unless proof["verified"] == true
      raise Error, :not_receivable unless account_check.call(account_id)

      activated = false
      hold_until = nil
      designer.with_lock do
        validate_challenge!(designer, message, expected_digest: expected_digest)
        if designer.payout_account_verified? && designer.hedera_account_id != account_id
          hold_until = REPLACEMENT_HOLD.from_now
          designer.update!(
            payout_proof_verified_at: Time.current,
            payout_hold_until: hold_until,
            payout_challenge: nil,
            payout_challenge_digest: nil,
            payout_challenge_expires_at: nil
          )
        else
          activate_locked!(designer, account_id)
          activated = true
        end
      end

      if activated
        PayoutDestinationMailer.activated(designer, account_id).deliver_later
        Designers::Notifier.record_later(designer: designer, kind: "payout_destination_activated",
          payload: { hedera_account_id: account_id })
      else
        PayoutDestinationMailer.safety_hold(designer, account_id, hold_until).deliver_later
        Designers::Notifier.record_later(designer: designer, kind: "payout_destination_hold",
          payload: { hedera_account_id: account_id, hold_until: hold_until&.iso8601 })
      end
      activated ? :activated : :safety_hold
    rescue SidecarClient::Unavailable
      raise Error, :verification_unavailable
    rescue SidecarClient::Rejected
      raise Error, :invalid_signature
    end

    def self.activate!(designer:)
      account_id = nil
      designer.with_lock do
        raise Error, :account_closed if designer.account_closed?

        raise Error, :no_pending_change unless designer.payout_proof_verified_at.present?
        raise Error, :hold_active if designer.payout_hold_until&.future?

        account_id = designer.payout_pending_account_id
        activate_locked!(designer, account_id)
      end
      PayoutDestinationMailer.activated(designer, account_id).deliver_later
      Designers::Notifier.record_later(designer: designer, kind: "payout_destination_activated",
        payload: { hedera_account_id: account_id })
      account_id
    end

    def self.cancel!(designer:)
      account_id = nil
      designer.with_lock do
        raise Error, :account_closed if designer.account_closed?

        raise Error, :no_pending_change unless designer.payout_destination_change_pending?

        account_id = designer.payout_pending_account_id
        clear_pending!(designer)
      end
      PayoutDestinationMailer.cancelled(designer, account_id).deliver_later
      Designers::Notifier.record_later(designer: designer, kind: "payout_destination_cancelled",
        payload: { hedera_account_id: account_id })
      account_id
    end

    def self.validate_challenge!(designer, message, expected_digest: nil)
      raise Error, :no_pending_change unless designer.payout_destination_change_pending?
      raise Error, :challenge_expired if designer.payout_challenge_expires_at&.past?

      actual = digest(message)
      expected = expected_digest || designer.payout_challenge_digest
      valid = expected.present? && actual.bytesize == expected.bytesize &&
        ActiveSupport::SecurityUtils.secure_compare(actual, expected)
      raise Error, :invalid_challenge unless valid && designer.payout_challenge == message
    end
    private_class_method :validate_challenge!

    def self.activate_locked!(designer, account_id)
      now = Time.current
      designer.hedera_account_id = account_id
      designer.save! # the model intentionally clears verification on a changed id
      designer.update!(
        payout_account_verified_at: now,
        payout_account_control_verified_at: now,
        payout_pending_account_id: nil,
        payout_challenge: nil,
        payout_challenge_digest: nil,
        payout_challenge_expires_at: nil,
        payout_change_requested_at: nil,
        payout_proof_verified_at: nil,
        payout_hold_until: nil
      )
    end
    private_class_method :activate_locked!

    def self.clear_pending!(designer)
      designer.update!(
        payout_pending_account_id: nil,
        payout_challenge: nil,
        payout_challenge_digest: nil,
        payout_challenge_expires_at: nil,
        payout_change_requested_at: nil,
        payout_proof_verified_at: nil,
        payout_hold_until: nil
      )
    end
    private_class_method :clear_pending!

    def self.challenge_for(designer, account_id)
      [
        "Printwright payout destination verification",
        "Network: #{Hedera::Network.name}",
        "Designer: #{designer.id}",
        "Account: #{account_id}",
        "Nonce: #{SecureRandom.hex(24)}"
      ].join("\n")
    end
    private_class_method :challenge_for

    def self.digest(message)
      Digest::SHA256.hexdigest(message)
    end
    private_class_method :digest
  end
end
