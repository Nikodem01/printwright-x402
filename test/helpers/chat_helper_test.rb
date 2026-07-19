require "test_helper"

class ChatHelperTest < ActionView::TestCase
  test "renders every text part in order" do
    turn = {
      "role" => "model",
      "parts" => [
        { "text" => "Cable " },
        { "text" => "Clip", "thoughtSignature" => "opaque" }
      ]
    }

    assert_equal :assistant_message, chat_turn_kind(turn)
    assert_equal "Cable Clip", chat_turn_text(turn)
  end

  test "recognizes and labels every parallel function call" do
    turn = {
      "role" => "model",
      "parts" => [
        { "text" => "Checking." },
        { "functionCall" => { "name" => "search_models", "args" => { "query" => "clip" } } },
        { "functionCall" => { "name" => "get_model", "args" => { "id" => "7" } } }
      ]
    }

    assert_equal :tool_call, chat_turn_kind(turn)
    assert_equal 'search_models(query: "clip"); get_model(id: "7")', chat_tool_call_label(turn)
  end

  test "recognizes a grouped function response even when it is not the first part" do
    turn = {
      "role" => "user",
      "parts" => [
        { "text" => "metadata" },
        { "functionResponse" => { "name" => "search_models", "response" => {} } }
      ]
    }

    assert_equal :tool_response, chat_turn_kind(turn)
  end
end
