require "test_helper"

class X402PaymentFuzzTest < ActiveSupport::TestCase
  Request = Struct.new(:headers)
  SEED = 40_245
  ITERATIONS = 2_000

  setup do
    ENV["X402_PAY_TO"] = "0.0.9584959"
    ENV["X402_DEMO_HBAR_PRICE_CENTS"] = "250"
    @model = Model3d.create!(
      designer: designers(:one), title: "Fuzz model", slug: "fuzz-#{SecureRandom.hex(4)}"
    )
    @offer = @model.license_offers.create!(kind: "personal", price_cents: 25, currency: "HBAR")
    @base_payload = JSON.parse(file_fixture("x402/payment_payload.json").read)
    FacilitatorClient.instance_variable_set(
      :@fee_payers, { X402::Requirements.network => "0.0.7162784" }
    )
    @requirements = X402::Requirements.new(offer: @offer, resource_url: "/fuzz")
  end

  teardown { FacilitatorClient.reset_cache! }

  test "committed payment mutation corpus only rejects or returns a safe payload" do
    corpus.each do |entry|
      header = header_for(entry)
      outcome = decode_and_match(header)
      assert_equal entry.fetch("expected"), outcome, entry.fetch("name")
    end
  end

  test "seeded structured mutations never escape as an unexpected exception" do
    random = Random.new(SEED)

    ITERATIONS.times do |iteration|
      header = generated_header(random)
      decoded = X402::PaymentHeader.decode(request_for(header))

      assert_kind_of Hash, decoded, "seed=#{SEED} iteration=#{iteration}"
      assert_kind_of Hash, decoded["accepted"], "seed=#{SEED} iteration=#{iteration}"
      assert_kind_of Hash, decoded["payload"], "seed=#{SEED} iteration=#{iteration}"
      assert decoded.dig("payload", "transaction").present?, "seed=#{SEED} iteration=#{iteration}"
      assert_includes [ nil, Hash ], @requirements.match(decoded["accepted"])&.class,
        "seed=#{SEED} iteration=#{iteration}"
    rescue X402::PaymentHeader::InvalidPayload
      assert true
    rescue StandardError => error
      flunk "seed=#{SEED} iteration=#{iteration} escaped #{error.class}: #{error.message}"
    end
  end

  private

  def corpus
    JSON.parse(file_fixture("x402/fuzz/corpus.json").read)
  end

  def request_for(header)
    Request.new({ "PAYMENT-SIGNATURE" => header })
  end

  def header_for(entry)
    return entry["raw"] if entry.key?("raw")
    return Base64.strict_encode64(entry["text"]) if entry.key?("text")
    return Base64.strict_encode64(JSON.generate(entry["json"])) if entry.key?("json")

    payload = @base_payload.deep_dup
    parent = entry.fetch("path")[0...-1].reduce(payload) { |value, key| value.fetch(key) }
    parent[entry.fetch("path").last] = entry["value"]
    Base64.strict_encode64(JSON.generate(payload))
  end

  def decode_and_match(header)
    decoded = X402::PaymentHeader.decode(request_for(header))
    @requirements.match(decoded["accepted"]) ? "decoded" : "requirements_mismatch"
  rescue X402::PaymentHeader::InvalidPayload
    "invalid_payload"
  end

  def generated_header(random)
    return random.rand(256) if random.rand(12).zero?
    return random.bytes(random.rand(0..48)) if random.rand(10).zero?
    return Base64.strict_encode64(random.bytes(random.rand(0..48))) if random.rand(8).zero?

    payload = random.rand(4).zero? ? generated_value(random) : @base_payload.deep_dup
    if payload.is_a?(Hash)
      path = [
        [ "accepted" ], [ "accepted", "amount" ], [ "accepted", "asset" ],
        [ "accepted", "payTo" ], [ "accepted", "network" ], [ "accepted", "scheme" ],
        [ "accepted", "extra" ], [ "payload" ], [ "payload", "transaction" ]
      ].sample(random: random)
      set_generated_value(payload, path, generated_value(random))
    end
    Base64.strict_encode64(JSON.generate(payload))
  end

  def set_generated_value(payload, path, value)
    parent = path[0...-1].reduce(payload) do |current, key|
      return unless current.is_a?(Hash)
      current[key]
    end
    parent[path.last] = value if parent.is_a?(Hash)
  end

  def generated_value(random)
    [
      nil, true, false, random.rand(-2..2), "", "0", "-1", random.bytes(4).unpack1("H*"),
      [], {}, [ "payment", "fee" ], { "feePayer" => "0.0.1" },
      { "transaction" => "signed-#{random.rand(1_000)}" },
      "9" * random.rand(1..128)
    ].sample(random: random)
  end
end
