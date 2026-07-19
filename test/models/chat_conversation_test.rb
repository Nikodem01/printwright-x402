require "test_helper"

class ChatConversationTest < ActiveSupport::TestCase
  test "starts with safe defaults and expires after 24 hours" do
    travel_to Time.zone.local(2026, 7, 19, 10, 0, 0) do
      conversation = ChatConversation.create!

      assert_equal [], conversation.turns
      assert_equal({}, conversation.purchase_proposal)
      assert_equal 0, conversation.approved_spend_cents
      assert_equal 24.hours.from_now, conversation.expires_at
      assert_equal 0, conversation.lock_version
    end
  end

  test "saving activity refreshes the expiry" do
    conversation = ChatConversation.create!
    original_expiry = conversation.expires_at

    travel 2.hours do
      conversation.update!(turns: [ user_text("hello") ])

      assert_equal 24.hours.from_now, conversation.expires_at
      assert_operator conversation.expires_at, :>, original_expiry
    end
  end

  test "active and expired scopes meet at the expiry boundary" do
    travel_to Time.zone.local(2026, 7, 19, 10, 0, 0) do
      active = ChatConversation.create!
      expired = ChatConversation.create!
      expired.update_column(:expires_at, Time.current)

      assert_equal [ active.id ], ChatConversation.active.pluck(:id)
      assert_equal [ expired.id ], ChatConversation.expired.pluck(:id)
    end
  end

  test "cleanup deletes only expired conversations" do
    active = ChatConversation.create!
    expired = ChatConversation.create!
    expired.update_column(:expires_at, 1.second.ago)

    assert_equal 1, ChatConversation.cleanup_expired!
    assert_equal [ active.id ], ChatConversation.pluck(:id)
  end

  test "trimming drops a whole old exchange without splitting its tool group" do
    old_exchange = [
      user_text("x" * ChatConversation::MAX_TURNS_BYTES),
      { "role" => "model", "parts" => [ { "functionCall" => { "name" => "search_models" } } ] },
      { "role" => "user", "parts" => [ { "functionResponse" => { "name" => "search_models" } } ] },
      { "role" => "model", "parts" => [ { "text" => "old answer" } ] }
    ]
    recent_exchange = [ user_text("new question"), { "role" => "model", "parts" => [ { "text" => "new answer" } ] } ]

    conversation = ChatConversation.create!(turns: old_exchange + recent_exchange)

    assert_equal recent_exchange, conversation.turns
    assert_operator JSON.generate(conversation.turns).bytesize, :<=, ChatConversation::MAX_TURNS_BYTES
  end

  test "an exchange larger than the cap is removed rather than partially stored" do
    oversized_exchange = [
      user_text("question"),
      { "role" => "model", "parts" => [ { "functionCall" => { "name" => "get_model" } } ] },
      { "role" => "user", "parts" => [ { "functionResponse" => {
        "name" => "get_model", "response" => { "description" => "x" * ChatConversation::MAX_TURNS_BYTES }
      } } ] },
      { "role" => "model", "parts" => [ { "text" => "answer" } ] }
    ]

    conversation = ChatConversation.create!(turns: oversized_exchange)

    assert_equal [], conversation.turns
  end

  test "optimistic locking rejects a stale writer" do
    conversation = ChatConversation.create!
    stale = ChatConversation.find(conversation.id)
    conversation.update!(purchase_proposal: { "model_id" => 1 })

    assert_raises(ActiveRecord::StaleObjectError) do
      stale.update!(purchase_proposal: { "model_id" => 2 })
    end
  end

  test "turns and proposal state are filtered from model and SQL inspection" do
    conversation = ChatConversation.new(
      turns: [ user_text("private chat sentence") ],
      purchase_proposal: { "title" => "private proposal title" }
    )

    refute_includes conversation.inspect, "private chat sentence"
    refute_includes conversation.inspect, "private proposal title"
    assert_includes conversation.inspect, "[FILTERED]"
  end

  private

  def user_text(text)
    { "role" => "user", "parts" => [ { "text" => text } ] }
  end
end
