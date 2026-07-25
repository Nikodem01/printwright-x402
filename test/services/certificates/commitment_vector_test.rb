require "test_helper"

class Certificates::CommitmentVectorTest < ActiveSupport::TestCase
  # This exact (certificate, nonce) -> commitment triple is asserted identically
  # in the JS verifier (verifier/test/verifier.test.js). It locks RFC 8785 JCS +
  # the commitment construction across Ruby (anchoring) and JS (verification):
  # if either side's canonicalization or domain/nonce framing drifts, one of the
  # two suites fails immediately.
  CERT = {
    "v" => 1, "cert_id" => "pw-abc123", "model_id" => 7, "model_hash" => "sha256:#{'a' * 64}",
    "designer" => 14, "license_type" => "personal", "unit_serial" => 3, "buyer_hint" => "bearer",
    "payment_tx" => "0.0.7@1.2", "issued_at" => "2026-07-25T00:00:00Z", "terms_hash" => "sha256:#{'b' * 64}"
  }.freeze
  NONCE = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff".freeze
  COMMITMENT = "2b523aa587fce40efab3395a2b074293eb2014cef5f82e844feb6e0a1df1e0fa".freeze

  test "commitment vector matches the JS verifier byte for byte" do
    assert_equal COMMITMENT, Certificates::Commitment.digest(CERT, NONCE)
  end

  test "canonicalization is order-independent (RFC 8785 sorts keys)" do
    assert_equal COMMITMENT, Certificates::Commitment.digest(CERT.to_a.shuffle.to_h, NONCE)
  end

  test "envelope carries the versioned type and algorithm" do
    env = Certificates::Commitment.envelope(CERT, NONCE)
    assert_equal [ "printwright-license-commitment", 1, "sha256-jcs-v1", COMMITMENT ],
                 env.values_at("type", "version", "algorithm", "commitment")
  end
end
