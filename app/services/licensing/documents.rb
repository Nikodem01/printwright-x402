module Licensing
  # Canonical license texts, file-backed and versioned. The committed file
  # bytes ARE the canonical form: `terms_hash` = "sha256:" + SHA-256 of the
  # exact bytes served at /license/:version/:kind.txt — recomputable by a
  # stranger with curl and sha256sum. Never edit a published version; add a
  # new version directory instead (existing certificates anchor the old hash).
  class Documents
    ROOT = Rails.root.join("app/licenses")

    # The version new offers publish under. Superseded versions stay on disk
    # forever: certificates anchor the hash of the bytes they were sold under,
    # and those bytes must remain fetchable to verify. Bump this (never edit a
    # published document) by adding app/licenses/vN/ and a migration that moves
    # existing offers forward.
    CURRENT_VERSION = "v2".freeze

    class UnknownDocument < StandardError; end

    def self.text(version, kind)
      path = ROOT.join(version.to_s, "#{kind}.md")
      raise UnknownDocument, "#{version}/#{kind}" unless path.file? && path.to_s.start_with?(ROOT.to_s)
      cache[[ version.to_s, kind.to_s ]] ||= path.read
    end

    def self.hash(version, kind)
      "sha256:#{Digest::SHA256.hexdigest(text(version, kind))}"
    end

    def self.exists?(version, kind)
      text(version, kind)
      true
    rescue UnknownDocument
      false
    end

    def self.version_for_hash(kind, terms_hash)
      return nil unless kind.to_s.match?(/\A[a-z_]+\z/) && terms_hash.to_s.start_with?("sha256:")

      ROOT.children.filter(&:directory?).filter_map do |directory|
        version = directory.basename.to_s
        next unless version.match?(/\Av\d+\z/)
        version if exists?(version, kind) && hash(version, kind) == terms_hash
      end.first
    end

    def self.cache
      @cache ||= {}
    end
  end
end
