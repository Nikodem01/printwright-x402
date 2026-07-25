require "digest"
require "json/canonicalization"

module Certificates
  # Privacy-preserving on-chain anchor. Only an opaque commitment to the full
  # certificate is published to HCS; the certificate itself and its blinding
  # nonce stay off-chain (delivered to the buyer as a portable proof bundle and
  # kept in our DB for convenience). A topic scraper therefore sees no designer
  # wallet, no buyer account, no model id, and no per-model count — yet any
  # holder can prove their certificate by revealing the preimage (cert + nonce)
  # and letting anyone recompute the hash (see Certificates::MirrorCheck and the
  # standalone verifier/ CLI).
  #
  # Construction (versioned + domain-separated so it can evolve safely):
  #
  #   commitment = SHA-256( DOMAIN || nonce_bytes || JCS(certificate) )
  #
  # where DOMAIN is a fixed byte string ending in NUL, the nonce is 32 random
  # bytes (hex-encoded off-chain), and JCS is RFC 8785 canonical JSON — the same
  # bytes in Ruby (here) and in the JS verifier, guaranteed by a shared test
  # vector. Naming: the algorithm is "sha256-jcs-v1"; the on-chain envelope type
  # is "printwright-license-commitment".
  module Commitment
    ALGORITHM = "sha256-jcs-v1".freeze
    TYPE = "printwright-license-commitment".freeze
    DOMAIN = "printwright:license-certificate:v1\0".b.freeze

    # The message written to the HCS topic: tiny, opaque, single-chunk.
    def self.envelope(cert, nonce_hex)
      {
        "type" => TYPE,
        "version" => 1,
        "algorithm" => ALGORITHM,
        "commitment" => digest(cert, nonce_hex)
      }
    end

    def self.digest(cert, nonce_hex)
      preimage = DOMAIN + [ nonce_hex.to_s ].pack("H*") + canonical(cert).b
      Digest::SHA256.hexdigest(preimage)
    end

    # RFC 8785 JSON Canonicalization Scheme — deterministic across languages.
    def self.canonical(cert)
      cert.to_json_c14n
    end

    # True for a message that is our commitment envelope (vs a legacy full-cert
    # message anchored before this scheme).
    def self.envelope?(message)
      message.is_a?(Hash) && message["type"] == TYPE
    end
  end
end
