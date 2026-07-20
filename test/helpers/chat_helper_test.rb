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

  test "extracts and deduplicates catalog cards from symbol or string keyed tool results" do
    turn = {
      "role" => "user",
      "parts" => [
        { "functionResponse" => { "name" => "search_models", "response" => {
          models: [ { id: 7, slug: "cable-clip", title: "Cable Clip" } ]
        } } },
        { "functionResponse" => { "name" => "get_model", "response" => {
          "id" => 7, "slug" => "cable-clip", "title" => "Cable Clip"
        } } }
      ]
    }

    results = chat_catalog_results(turn)
    assert_equal 1, results.length
    assert_equal "cable-clip", results.first[:slug]
  end

  test "cleans stray Markdown markers from assistant copy" do
    turn = { "role" => "model", "parts" => [ { "text" => "**Found one**\n* **Personal:** 0.90 USDC" } ] }

    assert_equal "Found one\n• Personal: 0.90 USDC", chat_assistant_text(turn)
  end

  test "uses the stored local storefront URL for older catalog results" do
    result = { url: "http://localhost:3000/models/cable-clip" }

    assert_equal "/models/cable-clip", chat_catalog_model_path(result)
  end
end
