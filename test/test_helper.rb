ENV["RAILS_ENV"] ||= "test"

# The suite must not depend on what happens to be in the developer's shell.
# A real GOOGLE_GENERATIVE_AI_API_KEY made search tests attempt live embedding
# calls (WebMock then failed them, and printed the key into the output), so the
# suite was green in CI and red for anyone actually set up to use the feature.
# Tests that exercise the semantic path set this themselves and stub the HTTP.
ENV.delete("GOOGLE_GENERATIVE_AI_API_KEY")
# A developer's configured public heartbeat topic must not make the suite call
# the live mirror. Heartbeat tests opt in explicitly and stub the response.
ENV.delete("HEDERA_HEARTBEAT_TOPIC_ID")

require_relative "../config/environment"
require "rails/test_help"
require_relative "test_helpers/session_test_helper"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end
