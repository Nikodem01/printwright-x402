class ChatConversation < ApplicationRecord
  LIFETIME = 24.hours
  MAX_TURNS_BYTES = 32.kilobytes

  scope :active, -> { where("expires_at > ?", Time.current) }
  scope :expired, -> { where(expires_at: ..Time.current) }

  before_validation :set_initial_expiry, on: :create
  before_validation :trim_turns_to_limit
  before_update :refresh_expiry

  validates :approved_spend_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :expires_at, presence: true

  def self.cleanup_expired!
    expired.delete_all
  end

  def self.trim_turns(turns, max_bytes: MAX_TURNS_BYTES)
    turns = Array(turns)
    return turns if JSON.generate(turns).bytesize <= max_bytes

    turns.each_index do |index|
      next unless user_text_turn?(turns[index])

      remaining = turns[index..]
      return remaining if JSON.generate(remaining).bytesize <= max_bytes
    end

    []
  end

  def refresh_expiry!
    update!(expires_at: LIFETIME.from_now)
  end

  def self.user_text_turn?(turn)
    turn["role"] == "user" && Array(turn["parts"]).any? { |part| part.key?("text") }
  end
  private_class_method :user_text_turn?

  private

  def set_initial_expiry
    self.expires_at ||= LIFETIME.from_now
  end

  def trim_turns_to_limit
    self.turns = self.class.trim_turns(turns)
  end

  def refresh_expiry
    self.expires_at = LIFETIME.from_now
  end
end
