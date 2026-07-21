# Static site-legal pages. Templates, honestly labeled — reviewed text
# replaces them before any mainnet launch.
class PagesController < ApplicationController
  def terms; end
  def privacy; end
  def takedown; end
  def badge; end
  def about; end
  def pricing; end

  def open_books
    @snapshot = OpenBooks::Snapshot.call
  end

  def chaos_log
    @heartbeat = Heartbeat::Snapshot.call
    @chaos_runs = [
      {
        date: "19 July 2026",
        name: "Money-path adversarial audit",
        commit: "6d4ed77",
        commit_url: "https://github.com/Nikodem01/printwright-x402/commit/6d4ed77",
        command: "bin/rails test test/controllers test/services",
        exercised: "Malformed and replayed payments, amount and asset substitution, expired intents, concurrent spend caps, and 64 random grant-token guesses.",
        result: "Zero open first-party security warnings after bounded mirror requests, TLS sidecar support, and narrowed error handling shipped."
      },
      {
        date: "19 July 2026",
        name: "Payment decoder fuzz + purchase state properties",
        commit: "c4f111a",
        commit_url: "https://github.com/Nikodem01/printwright-x402/commit/c4f111a",
        command: "bin/rails test test/fuzz",
        exercised: "A committed malformed corpus, 2,000 seeded structured payment mutations, every declared state/target pair, and 80 seeded 12-step transition sequences.",
        result: "Zero unexpected exceptions; money-moved purchases never re-entered a pre-money state. Two decoder crash classes found by the corpus were fixed before this run passed."
      }
    ]
  end

  # Endpoint reference is rendered from the spec at request time, not
  # hand-duplicated, so the page and public/openapi.json can't drift apart.
  def docs
    @openapi = JSON.parse(Rails.root.join("public/openapi.json").read)
  end
end
