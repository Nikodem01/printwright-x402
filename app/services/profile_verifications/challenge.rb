module ProfileVerifications
  class Challenge
    def self.call(designer, profile_url)
      uri = Fetcher.validate_uri!(profile_url)
      nonce = SecureRandom.urlsafe_base64(24)
      signed = Rails.application.message_verifier("designer-profile").generate(
        { designer_id: designer.id, nonce: nonce }, expires_in: 2.days
      )
      designer.profile_verifications.create!(
        profile_url: uri.to_s, host: uri.host,
        challenge_token: "printwright-proof:#{signed}", expires_at: 2.days.from_now
      )
    end
  end
end
