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
        webhook_endpoints: webhooks_data
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
        email_verified: designer.email_verified?,
        identity_verified: designer.identity_verified?,
        payout_account_verified: designer.payout_account_verified?,
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
  end
end
