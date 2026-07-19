require "net/http"

module Chat
  # Turns one pending, server-stored proposal into a cap-checked exact-USDC
  # quote. The browser receives the quote only after this service atomically
  # reserves the conversation and daily budgets.
  class PurchaseApproval
    DAILY_LOCK_ID = 1_907_193_042
    TIMEOUT_SECONDS = 5

    Result = Struct.new(:payment_required, :purchase_url, :purchase_intent, keyword_init: true)

    class Failure < StandardError
      attr_reader :code, :status, :retry_after

      def initialize(code, status: :unprocessable_content, retry_after: nil)
        @code = code
        @status = status
        @retry_after = retry_after
        super(code)
      end
    end

    def self.call(conversation:, base_url:)
      new(conversation: conversation, base_url: base_url).call
    end

    def initialize(conversation:, base_url:)
      @conversation = conversation
      @base_url = base_url.delete_suffix("/")
    end

    def call
      fail_with("purchases_disabled", status: :forbidden) unless Chat::PurchasePolicy.enabled?

      proposal = @conversation.purchase_proposal.deep_stringify_keys
      validate_pending_or_approved!(proposal)
      purchase_url = "#{@base_url}#{proposal.fetch('purchase_path')}"
      quote = fetch_quote(purchase_url)
      usdc = validate_quote!(quote, proposal, purchase_url)

      approved = reserve!(proposal, usdc)
      Result.new(
        payment_required: quote.merge("accepts" => [ usdc ]),
        purchase_url: purchase_url,
        purchase_intent: Chat::PurchaseIntent.issue(conversation: @conversation, proposal: approved)
      )
    rescue KeyError
      fail_with("invalid_proposal", status: :conflict)
    end

    private

    def validate_pending_or_approved!(proposal)
      fail_with("approval_required", status: :conflict) if proposal.empty?
      fail_with("approval_already_used", status: :conflict) unless %w[pending approved].include?(proposal["state"])
      expires_at = Time.iso8601(proposal.fetch("expires_at"))
      fail_with("approval_expired", status: :gone) unless expires_at.future?
    rescue ArgumentError
      fail_with("invalid_proposal", status: :conflict)
    end

    def fetch_quote(purchase_url)
      uri = URI(purchase_url)
      response = Net::HTTP.start(
        uri.host, uri.port, use_ssl: uri.scheme == "https",
        open_timeout: TIMEOUT_SECONDS, read_timeout: TIMEOUT_SECONDS
      ) { |http| http.get(uri.request_uri, "accept" => "application/json") }

      unless response.code.to_i == 402
        code = response.code.to_i == 410 ? "sold_out" : "stale_proposal"
        fail_with(code, status: response.code.to_i == 410 ? :gone : :conflict)
      end
      JSON.parse(response.body)
    rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET, SocketError
      fail_with("approval_unavailable", status: :service_unavailable, retry_after: 5)
    rescue JSON::ParserError
      fail_with("invalid_payment_requirements", status: :bad_gateway)
    end

    def validate_quote!(quote, proposal, purchase_url)
      unless quote["x402Version"] == 2 && quote.dig("resource", "url") == purchase_url
        fail_with("stale_proposal", status: :conflict)
      end

      usdc = Array(quote["accepts"]).find { |accept| accept["asset"] == X402::Requirements.usdc_asset }
      fail_with("invalid_payment_requirements", status: :bad_gateway) unless usdc

      amount = usdc["amount"].to_s
      fail_with("invalid_payment_requirements", status: :bad_gateway) unless amount.match?(/\A[1-9]\d*\z/)
      base_units = amount.to_i
      units_per_cent = X402::Requirements::USDC_BASE_UNITS_PER_CENT
      unless (base_units % units_per_cent).zero? && base_units / units_per_cent == proposal["price_cents"]
        fail_with("stale_proposal", status: :conflict)
      end
      if proposal["price_cents"] > Chat::PurchasePolicy.max_spend_cents
        fail_with("spend_cap_exceeded")
      end

      usdc
    end

    def reserve!(snapshot, usdc)
      @conversation.with_lock do
        lock_daily_budget!
        proposal = @conversation.purchase_proposal.deep_stringify_keys
        fail_with("stale_proposal", status: :conflict) unless proposal["nonce"] == snapshot["nonce"]

        if proposal["state"] == "pending"
          price_cents = proposal.fetch("price_cents")
          if @conversation.approved_spend_cents + price_cents > Chat::PurchasePolicy.max_spend_cents
            fail_with("spend_cap_exceeded")
          end
          if approved_today_cents + price_cents > Chat::PurchasePolicy.daily_spend_cents
            fail_with("daily_spend_cap_exceeded")
          end

          proposal.merge!(
            "state" => "approved",
            "approved_at" => Time.current.iso8601,
            "approved_asset" => usdc.fetch("asset"),
            "approved_amount" => usdc.fetch("amount")
          )
          @conversation.update!(
            purchase_proposal: proposal,
            approved_spend_cents: @conversation.approved_spend_cents + price_cents
          )
        elsif proposal["state"] != "approved" || proposal["approved_amount"] != usdc["amount"]
          fail_with("approval_already_used", status: :conflict)
        end

        proposal
      end
    end

    def lock_daily_budget!
      return unless ActiveRecord::Base.connection.adapter_name == "PostgreSQL"

      ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock(#{DAILY_LOCK_ID})")
    end

    def approved_today_cents
      ChatConversation.where(updated_at: Time.current.beginning_of_day..).sum(:approved_spend_cents)
    end

    def fail_with(code, **)
      raise Failure.new(code, **)
    end
  end
end
