require "test_helper"

class Designers::PayoutDestinationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  class ProofClient
    attr_reader :calls

    def initialize(verified: true)
      @verified = verified
      @calls = []
    end

    def verify_payout_proof(**args)
      @calls << args
      { "verified" => @verified }
    end
  end

  ReadyAccount = ->(_account_id) { true }
  UnreadyAccount = ->(_account_id) { false }

  setup do
    @designer = designers(:two)
    @designer.update!(hedera_account_id: nil, payout_account_verified_at: nil)
    clear_enqueued_jobs
  end

  test "request stages a single-use account-bound challenge without changing the active destination" do
    challenge = Designers::PayoutDestination.request!(designer: @designer, account_id: " 0.0.7007 ")

    @designer.reload
    assert_equal "0.0.7007", @designer.payout_pending_account_id
    assert_nil @designer.hedera_account_id
    assert_equal :awaiting_proof, @designer.payout_destination_state
    assert_includes challenge, "Network: testnet"
    assert_includes challenge, "Designer: #{@designer.id}"
    assert_includes challenge, "Account: 0.0.7007"
    assert_equal Digest::SHA256.hexdigest(challenge), @designer.payout_challenge_digest
    assert_equal 1, enqueued_jobs.count { |job| job[:job] == ActionMailer::MailDeliveryJob }
    notification = @designer.seller_notifications.sole
    assert_equal "payout_destination_staged", notification.kind
    assert_equal "0.0.7007", notification.payload["hedera_account_id"]
  end

  test "first destination activates only after wallet control and receipt checks pass" do
    message = Designers::PayoutDestination.request!(designer: @designer, account_id: "0.0.7007")
    client = ProofClient.new

    result = Designers::PayoutDestination.verify!(
      designer: @designer, message: message, signature_map: "signature-map", client: client,
      account_check: ReadyAccount
    )

    assert_equal :activated, result
    @designer.reload
    assert_equal "0.0.7007", @designer.hedera_account_id
    assert @designer.payout_account_verified?
    assert @designer.payout_account_control_verified_at.present?
    assert_equal :active, @designer.payout_destination_state
    assert_not @designer.payout_destination_change_pending?
    assert_equal "0.0.7007", client.calls.sole.fetch(:account_id)
    activated_notification = @designer.seller_notifications.find_by!(kind: "payout_destination_activated")
    assert_equal "0.0.7007", activated_notification.payload["hedera_account_id"]
  end

  test "replacement keeps the old destination active through a cancellable 24-hour hold" do
    @designer.update!(hedera_account_id: "0.0.6006")
    @designer.update!(payout_account_verified_at: Time.current,
      payout_account_control_verified_at: Time.current)
    message = Designers::PayoutDestination.request!(designer: @designer, account_id: "0.0.7007")

    result = Designers::PayoutDestination.verify!(
      designer: @designer, message: message, signature_map: "signature-map",
      client: ProofClient.new, account_check: ReadyAccount
    )

    assert_equal :safety_hold, result
    @designer.reload
    assert_equal "0.0.6006", @designer.hedera_account_id
    assert @designer.payout_account_verified?
    assert_equal :safety_hold, @designer.payout_destination_state
    assert_in_delta 24.hours.from_now, @designer.payout_hold_until, 2.seconds
    hold_notification = @designer.seller_notifications.find_by!(kind: "payout_destination_hold")
    assert_equal "0.0.7007", hold_notification.payload["hedera_account_id"]
    assert hold_notification.payload["hold_until"].present?

    error = assert_raises(Designers::PayoutDestination::Error) do
      Designers::PayoutDestination.activate!(designer: @designer)
    end
    assert_equal :hold_active, error.code
    assert_not @designer.seller_notifications.exists?(kind: "payout_destination_activated")

    travel 24.hours + 1.second do
      assert_equal "0.0.7007", Designers::PayoutDestination.activate!(designer: @designer)
    end
    assert_equal "0.0.7007", @designer.reload.hedera_account_id
    assert @designer.payout_account_verified?
    activated_notification = @designer.seller_notifications.find_by!(kind: "payout_destination_activated")
    assert_equal "0.0.7007", activated_notification.payload["hedera_account_id"]
  end

  test "tampered, expired, invalid-signature, and non-receivable proofs fail closed" do
    message = Designers::PayoutDestination.request!(designer: @designer, account_id: "0.0.7007")

    error = assert_raises(Designers::PayoutDestination::Error) do
      Designers::PayoutDestination.verify!(
        designer: @designer, message: "#{message}x", signature_map: "sig", client: ProofClient.new
      )
    end
    assert_equal :invalid_challenge, error.code

    travel 16.minutes do
      error = assert_raises(Designers::PayoutDestination::Error) do
        Designers::PayoutDestination.verify!(
          designer: @designer, message: message, signature_map: "sig", client: ProofClient.new
        )
      end
      assert_equal :challenge_expired, error.code
    end

    Designers::PayoutDestination.request!(designer: @designer, account_id: "0.0.7007")
    message = @designer.reload.payout_challenge
    error = assert_raises(Designers::PayoutDestination::Error) do
      Designers::PayoutDestination.verify!(
        designer: @designer, message: message, signature_map: "sig",
        client: ProofClient.new(verified: false)
      )
    end
    assert_equal :invalid_signature, error.code

    error = assert_raises(Designers::PayoutDestination::Error) do
      Designers::PayoutDestination.verify!(
        designer: @designer, message: message, signature_map: "sig", client: ProofClient.new,
        account_check: UnreadyAccount
      )
    end
    assert_equal :not_receivable, error.code
    assert_nil @designer.reload.hedera_account_id
  end

  test "cancel is the recovery path and never changes the active destination" do
    @designer.update!(hedera_account_id: "0.0.6006")
    @designer.update!(payout_account_verified_at: Time.current)
    Designers::PayoutDestination.request!(designer: @designer, account_id: "0.0.7007")

    assert_equal "0.0.7007", Designers::PayoutDestination.cancel!(designer: @designer)
    @designer.reload
    assert_equal "0.0.6006", @designer.hedera_account_id
    assert @designer.payout_account_verified?
    assert_not @designer.payout_destination_change_pending?
    cancelled_notification = @designer.seller_notifications.find_by!(kind: "payout_destination_cancelled")
    assert_equal "0.0.7007", cancelled_notification.payload["hedera_account_id"]
  end

  test "legacy active destination can gain control proof without a replacement hold" do
    @designer.update!(hedera_account_id: "0.0.6006")
    @designer.update!(payout_account_verified_at: Time.current)
    message = Designers::PayoutDestination.request!(designer: @designer, account_id: "0.0.6006")

    result = Designers::PayoutDestination.verify!(
      designer: @designer, message: message, signature_map: "sig", client: ProofClient.new,
      account_check: ReadyAccount
    )

    assert_equal :activated, result
    assert @designer.reload.payout_account_control_verified_at.present?
    assert_nil @designer.payout_hold_until
  end

  test "a concurrent request cannot recreate payout state after account closure" do
    @designer.update!(status: :closed)

    error = assert_raises(Designers::PayoutDestination::Error) do
      Designers::PayoutDestination.request!(designer: @designer, account_id: "0.0.7007")
    end

    assert_equal :account_closed, error.code
    assert_not @designer.reload.payout_destination_change_pending?
  end
end
