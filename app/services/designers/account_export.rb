module Designers
  # GDPR data export (U2): a portable JSON dump of everything we hold about a
  # designer. Never includes credential material (password digest, OTP keys).
  class AccountExport
    def initialize(designer)
      @designer = designer
    end

    def to_json(*)
      {
        exported_at: Time.current.iso8601,
        account: account_data,
        models: models_data,
        identity_verifications: verifications_data,
        webhook_endpoints: webhooks_data,
        payout_attempts: payout_attempts_data,
        model_metrics: model_metrics_data,
        notifications: notifications_data
      }.to_json
    end

    private

    attr_reader :designer

    def account_data
      {
        id: designer.id,
        email_address: designer.email_address,
        display_name: designer.display_name,
        bio: designer.bio,
        hedera_account_id: designer.hedera_account_id,
        payout_pending_account_id: designer.payout_pending_account_id,
        email_verified: designer.email_verified?,
        identity_verified: designer.identity_verified?,
        payout_account_verified: designer.payout_account_verified?,
        payout_account_control_verified_at: designer.payout_account_control_verified_at&.iso8601,
        payout_change_requested_at: designer.payout_change_requested_at&.iso8601,
        payout_hold_until: designer.payout_hold_until&.iso8601,
        created_at: designer.created_at&.iso8601
      }
    end

    def models_data
      designer.models3d.map do |model|
        { title: model.title, slug: model.slug, status: model.status,
          created_at: model.created_at&.iso8601 }
      end
    end

    def verifications_data
      designer.profile_verifications.map do |verification|
        { host: verification.host, profile_url: verification.profile_url,
          status: verification.status, created_at: verification.created_at&.iso8601 }
      end
    end

    def webhooks_data
      designer.webhook_endpoints.map do |endpoint|
        { url: endpoint.url, events: endpoint.events, active: endpoint.active,
          created_at: endpoint.created_at&.iso8601 }
      end
    end

    def payout_attempts_data
      designer.payout_attempts.map do |attempt|
        {
          purchase_id: attempt.purchase_id, asset: attempt.asset, status: attempt.status,
          attempt_count: attempt.attempt_count, last_error_code: attempt.last_error_code,
          tx_id: attempt.tx_id, last_attempted_at: attempt.last_attempted_at&.iso8601,
          completed_at: attempt.completed_at&.iso8601
        }
      end
    end

    def notifications_data
      designer.seller_notifications.recent.map do |notification|
        {
          kind: notification.kind, payload: notification.payload,
          created_at: notification.created_at&.iso8601, read_at: notification.read_at&.iso8601
        }
      end
    end

    def model_metrics_data
      ModelMetric.joins(:model3d).where(models3d: { designer_id: designer.id })
        .order(:occurred_on, :model3d_id, :channel, :source).map do |metric|
        {
          model_id: metric.model3d_id, occurred_on: metric.occurred_on.iso8601,
          channel: metric.channel, source: metric.source,
          impressions: metric.impressions, views: metric.views,
          payment_requests: metric.payment_requests
        }
      end
    end
  end
end
