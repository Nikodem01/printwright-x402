module Licensing
  # Canonical license texts, file-backed and versioned. The committed file
  # bytes ARE the canonical form: `terms_hash` = "sha256:" + SHA-256 of the
  # exact bytes served at /license/:version/:kind.txt — recomputable by a
  # stranger with curl and sha256sum. Never edit a published version; add a
  # new version directory instead (existing certificates anchor the old hash).
  class Documents
    ROOT = Rails.root.join("app/licenses")

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

    def self.cache
      @cache ||= {}
    end
  end
end
