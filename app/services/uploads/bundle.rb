module Uploads
  # Bundle-level checks — the rules that only mean anything across a whole set
  # of files, kept in one place so every door (interactive upload, version
  # upload, ZIP import, external profile) enforces the same thing.
  #
  # Each door hands over the same shape: [{ kind:, filename:, digest: }, ...].
  # As with Uploads::Validator, the errors are written for the designer.
  class Bundle
    ANALYZABLE_KINDS = MeshAnalysis::Analyzer::SUPPORTED_KINDS

    # A buyer is promised that what they receive was geometry-checked, and we
    # can only check STL and 3MF. A bundle made only of formats we cannot read
    # would ship entirely unverified, so it needs at least one file we can
    # actually inspect. Other formats are welcome alongside it.
    # => nil when acceptable, else a designer-readable reason
    def self.missing_analyzable_reason(files)
      return nil if files.empty?
      return nil if files.any? { |file| ANALYZABLE_KINDS.include?(file.fetch(:kind)) }

      names = files.map { |file| file.fetch(:filename) }.join(", ")
      "Add an STL or 3MF file — we check printable geometry before buyers receive it, and we " \
        "cannot read #{names}. Keep those alongside it as source files."
    end

    # A buyer told a listing includes several files should receive several
    # files, not one file under several names. Digests are only ever compared
    # with each other inside a single bundle, so each door may supply whichever
    # digest it already has to hand.
    # => nil when acceptable, else a designer-readable reason
    def self.duplicate_reason(files)
      seen = {}
      files.each do |file|
        digest = file.fetch(:digest)
        name = file.fetch(:filename)
        if (original = seen[digest])
          return "#{name} is byte-identical to #{original} — remove one, or upload the file you meant to include."
        end

        seen[digest] = name
      end
      nil
    end
  end
end
