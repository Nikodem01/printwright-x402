# Public shopkeeper chat. The signed session cookie carries only an opaque
# conversation id; provider turns and purchase authorization state stay in a
# dedicated, expiring database row.
class ChatController < ApplicationController
  allow_unauthenticated_access

  MAX_MESSAGE_BYTES = 4.kilobytes

  rate_limit to: 10, within: 1.minute, only: :create, store: RateLimitStore,
    name: "messages", with: :chat_rate_limited
  rate_limit to: 5, within: 1.minute, only: :approve, store: RateLimitStore,
    name: "approvals", with: :chat_rate_limited

  before_action :load_conversation

  def show
    assign_conversation
  end

  def create
    text = params[:message].to_s.strip
    @new_turns = []

    if text.present?
      # Active Record's development SQL log prints JSONB bind values in full;
      # parameter filtering alone cannot redact a transcript embedded in an
      # UPDATE. Silence this thread's non-error logs across the persistence
      # block so private chat text and opaque thought signatures never land in
      # logs. Request metadata remains logged with params filtered.
      Rails.logger.silence do
        @conversation.with_lock do
          turns = @conversation.turns.deep_dup
          start = turns.length
          if text.bytesize > MAX_MESSAGE_BYTES
            turns.concat([
              { "role" => "user", "parts" => [ { "text" => "[message rejected: over 4 KiB]" } ] },
              { "role" => "model", "parts" => [ { "text" => "That message is too long. Please keep it under 4 KiB." } ] }
            ])
          else
            turns << { "role" => "user", "parts" => [ { "text" => text } ] }
            client = Chat::Gemini.new
            if !client.available?
              turns << { "role" => "model", "parts" => [ { "text" => Chat::ToolLoop::NOT_CONFIGURED_MESSAGE } ] }
            elsif Chat::UsageBudget.consume_visitor_message?(visitor_key)
              turns = Chat::ToolLoop.new(turns: turns, client: client).run.turns
            else
              turns << { "role" => "model", "parts" => [ {
                "text" => Chat::UsageBudget.visitor_limit_message
              } ] }
            end
          end
          @new_turns = turns[start..] || []

          proposal = proposal_from(@new_turns, current: @conversation.purchase_proposal)
          @conversation.update!(turns: turns, purchase_proposal: proposal)
        end
      end
    end

    assign_conversation
    respond_to { |format| format.turbo_stream }
  end

  def destroy
    @conversation.destroy!
    session.delete(:chat_conversation_id)
    redirect_back fallback_location: chat_path, status: :see_other
  end

  # No model, license, URL, price, asset, or amount parameters are accepted.
  # All authority comes from the current conversation's stored proposal.
  def approve
    result = Chat::PurchaseApproval.call(conversation: @conversation, base_url: request.base_url)
    render json: {
      payment_required: result.payment_required,
      purchase_url: result.purchase_url,
      purchase_intent: result.purchase_intent
    }
  rescue Chat::PurchaseApproval::Failure => e
    response.set_header("Retry-After", e.retry_after.to_s) if e.retry_after
    render json: { error: e.code, retry_after: e.retry_after }.compact, status: e.status
  end

  private

  def load_conversation
    session.delete(:chat_turns)
    @conversation = ChatConversation.active.find_by(id: session[:chat_conversation_id])
    return if @conversation

    @conversation = ChatConversation.create!
    session[:chat_conversation_id] = @conversation.id
  end

  def assign_conversation
    @turns = @conversation.turns
    @purchase_proposal = @conversation.purchase_proposal.deep_stringify_keys
    @chat_spend_cap_cents = Chat::PurchasePolicy.max_spend_cents
  end

  def proposal_from(turns, current:)
    responses = turns.flat_map { |turn| Array(turn["parts"]) }
      .filter_map { |part| part["functionResponse"] }
      .select { |response| response["name"] == "propose_purchase" }
    return current if responses.empty?

    proposals = responses.filter_map { |response| response["response"]&.deep_stringify_keys&.fetch("proposal", nil) }
    return {} unless proposals.one?

    proposals.first.merge(
      "nonce" => SecureRandom.hex(16),
      "state" => "pending"
    )
  end

  def chat_rate_limited
    response.set_header("Retry-After", "60")
    render json: { error: "rate_limited", retry_after: 60 }, status: :too_many_requests
  end

  def visitor_key
    Digest::SHA256.hexdigest(request.remote_ip.to_s)
  end
end
