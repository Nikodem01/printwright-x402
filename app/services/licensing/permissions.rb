module Licensing
  # Machine-decidable interpretation of a canonical license document. The
  # prose remains the legal grant and its hash is what HCS anchors; this JSON
  # is a convenience layer and is used only when that anchored hash matches.
  class Permissions
    ROOT = Documents::ROOT
    USES = %w[
      personal_print commercial_print resell_files share_files
      personal_remix commercial_remix transfer_license sublicense
    ].freeze

    class UnknownDocument < StandardError; end

    def self.document(version, kind)
      key = [ version.to_s, kind.to_s ]
      cache[key] ||= begin
        path = ROOT.join(key.first, "#{key.last}.json")
        raise UnknownDocument, key.join("/") unless path.file? && path.to_s.start_with?(ROOT.to_s)

        freeze_tree(JSON.parse(path.read))
      rescue JSON::ParserError
        raise UnknownDocument, key.join("/")
      end
    end

    def self.for_license(license)
      offer = license.license_offer
      anchored_hash = license.cert_json["terms_hash"]
      version = Documents.version_for_hash(offer.kind, anchored_hash)
      return nil unless version

      {
        version: version,
        kind: offer.kind,
        terms_hash: anchored_hash,
        document: document(version, offer.kind)
      }
    rescue Documents::UnknownDocument, UnknownDocument
      nil
    end

    def self.decide(document, use, quantity)
      case use
      when "personal_print"
        decision(document.dig("personal_use", "allowed"), "personal use is granted", "personal_use_not_granted")
      when "commercial_print"
        max = document.dig("commercial_units", "max_units").to_i
        allowed = document.dig("commercial_units", "allowed") && quantity <= max
        if allowed
          { allowed: true, reason_code: "allowed", reason: "this certificate covers #{quantity} commercial unit" }
        elsif max.zero?
          { allowed: false, reason_code: "commercial_use_not_granted",
            reason: "commercial printing is not granted by this license" }
        else
          { allowed: false, reason_code: "commercial_unit_limit",
            reason: "this certificate covers at most #{max} commercial units; acquire one per unit sold" }
        end
      when "resell_files"
        decision(document.dig("resale_files", "allowed"), "digital file resale is granted", "digital_file_resale_prohibited")
      when "share_files"
        decision(document.dig("share_files", "allowed"), "digital file sharing is granted", "digital_file_sharing_prohibited")
      when "personal_remix"
        allowed = document.dig("remix", "allowed") && document.dig("remix", "scope") == "personal_noncommercial_only"
        decision(allowed, "personal, non-commercial modification is granted", "personal_remix_not_granted")
      when "commercial_remix"
        decision(false, "commercial use of a modified model is not granted", "commercial_remix_not_granted")
      when "transfer_license"
        decision(document.dig("transfer", "allowed"), "license transfer is granted", "license_non_transferable")
      when "sublicense"
        decision(document.dig("sublicense", "allowed"), "sublicensing is granted", "sublicensing_prohibited")
      end
    end

    def self.cache
      @cache ||= {}
    end

    def self.freeze_tree(value)
      value.each { |key, child| freeze_tree(key); freeze_tree(child) } if value.is_a?(Hash)
      value.each { |child| freeze_tree(child) } if value.is_a?(Array)
      value.freeze
    end
    private_class_method :freeze_tree

    def self.decision(allowed, allowed_reason, denied_code)
      {
        allowed: allowed == true,
        reason_code: allowed == true ? "allowed" : denied_code,
        reason: allowed == true ? allowed_reason : denied_reason(denied_code)
      }
    end
    private_class_method :decision

    DENIED_REASONS = {
      "personal_use_not_granted" => "personal printing is not granted",
      "digital_file_resale_prohibited" => "resale of digital files is prohibited",
      "digital_file_sharing_prohibited" => "sharing or redistributing digital files is prohibited",
      "personal_remix_not_granted" => "personal modification is not granted",
      "license_non_transferable" => "the license is non-transferable",
      "sublicensing_prohibited" => "sublicensing is prohibited"
    }.freeze

    def self.denied_reason(code)
      DENIED_REASONS.fetch(code)
    end
    private_class_method :denied_reason
  end
end
