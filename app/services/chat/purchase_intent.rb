module Chat
  # Short-lived, signed route binding for a chat-approved payment. The token
  # never enters the conversation or database; the database stores only its
  # public nonce and the digest of the one transaction allowed to use it.
  module PurchaseIntent
    HEADER = "X-Printwright-Purchase-Intent"
    PURPOSE = "chat-purchase-v1"

    Context = Data.define(:conversation_id, :nonce, :transaction_digest)

    class Invalid < StandardError
      attr_reader :code

      def initialize(code = "invalid_purchase_intent")
        @code = code
        super(code)
      end
    end

    module_function

    def issue(conversation:, proposal:)
      expires_at = Time.iso8601(proposal.fetch("expires_at"))
      verifier.generate(
        {
          "conversation_id" => conversation.id,
          "nonce" => proposal.fetch("nonce"),
          "model_id" => proposal.fetch("model_id"),
          "license_kind" => proposal.fetch("license_kind"),
          "price_cents" => proposal.fetch("price_cents"),
          "asset" => proposal.fetch("approved_asset"),
          "amount" => proposal.fetch("approved_amount"),
          "purchase_path" => proposal.fetch("purchase_path")
        },
        expires_in: [ expires_at - Time.current, 1.second ].max,
        purpose: PURPOSE
      )
    end

    def authorize!(token:, offer:, request_path:, payload:, matched:)
      data = verifier.verify(token, purpose: PURPOSE).deep_stringify_keys
      conversation = ChatConversation.find(data.fetch("conversation_id"))
      transaction_digest = Digest::SHA256.hexdigest(payload.dig("payload", "transaction"))

      conversation.with_lock do
        proposal = conversation.purchase_proposal.deep_stringify_keys
        validate_binding!(data, proposal, offer, request_path, matched)

        case proposal["state"]
        when "approved"
          proposal["state"] = "submitting"
          proposal["transaction_digest"] = transaction_digest
          conversation.update!(purchase_proposal: proposal)
        when "submitting"
          raise Invalid, "payment_intent_replayed" unless proposal["transaction_digest"] == transaction_digest
        else
          raise Invalid, "approval_already_used"
        end
      end

      Context.new(conversation_id: conversation.id, nonce: data.fetch("nonce"), transaction_digest: transaction_digest)
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound, KeyError, ArgumentError
      raise Invalid
    end

    def complete!(context)
      conversation = ChatConversation.find_by(id: context.conversation_id)
      return unless conversation

      conversation.with_lock do
        proposal = conversation.purchase_proposal.deep_stringify_keys
        return unless proposal["nonce"] == context.nonce &&
          proposal["transaction_digest"] == context.transaction_digest && proposal["state"] == "submitting"

        proposal["state"] = "completed"
        proposal["completed_at"] = Time.current.iso8601
        conversation.update!(purchase_proposal: proposal)
      end
    end

    def validate_binding!(data, proposal, offer, request_path, matched)
      expected = {
        "nonce" => proposal["nonce"],
        "model_id" => offer.model3d_id,
        "license_kind" => offer.kind,
        "price_cents" => offer.price_cents,
        "asset" => matched[:asset] || matched["asset"],
        "amount" => matched[:amount] || matched["amount"],
        "purchase_path" => request_path
      }
      expected.each { |key, value| raise Invalid unless data[key].to_s == value.to_s }
      raise Invalid unless proposal["expires_at"].present? && Time.iso8601(proposal["expires_at"]).future?
    end
    private_class_method :validate_binding!

    def verifier
      Rails.application.message_verifier(PURPOSE)
    end
    private_class_method :verifier
  end
end
