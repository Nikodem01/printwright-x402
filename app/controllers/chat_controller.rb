# The shopkeeper chat (door 3, V30 part 1): search and inspect the catalog
# in conversation, via the tool loop over our own public API. Read-only —
# buying is a later slice. No accounts, no persistence: the conversation
# lives entirely in the session, Gemini's own turn shape end to end.
class ChatController < ApplicationController
  allow_unauthenticated_access

  # A cookie session has a hard ~4KB budget once signed and encoded — a real
  # multi-question conversation (each answer carrying tool-call + search-result
  # turns) hits that within a handful of exchanges. Bound by serialized size,
  # not turn count, so it actually stays under the limit instead of just
  # under some arbitrary count that still overflows.
  MAX_SESSION_BYTES = 2500

  def show
    @turns = session[:chat_turns] ||= []
  end

  def create
    text = params[:message].to_s.strip
    turns = session[:chat_turns] ||= []

    if text.present?
      start = turns.length
      turns << { "role" => "user", "parts" => [ { "text" => text } ] }
      result = Chat::ToolLoop.new(turns: turns).run
      @new_turns = result.turns[start..] || []
      session[:chat_turns] = trim(result.turns)
    else
      @new_turns = []
    end

    respond_to do |format|
      format.turbo_stream
    end
  end

  private

  # Drops whole oldest exchanges — never mid functionCall/functionResponse
  # pair — until the serialized history fits the session budget. Falls back
  # to keeping just the most recent exchange if even that alone doesn't fit.
  def trim(turns)
    boundaries = turns.each_index.select { |i| user_message?(turns[i]) }
    boundaries.each do |start|
      remaining = turns[start..]
      return remaining if JSON.generate(remaining).bytesize <= MAX_SESSION_BYTES
    end
    boundaries.any? ? turns[boundaries.last..] : turns
  end

  def user_message?(turn)
    turn["role"] == "user" && turn["parts"]&.first&.key?("text")
  end
end
