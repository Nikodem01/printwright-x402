module PreviewMeshes
  class Attacher
    def self.call(model)
      source = model.printable_files.find { |file| %w[stl 3mf].include?(file.kind) && file.file.attached? }
      return false unless source

      bytes = Generator.call(bytes: source.file.download, kind: source.kind)
      return false unless bytes

      preview = model.model_files.find_or_initialize_by(kind: "preview")
      preview.position ||= model.model_files.maximum(:position).to_i + 1
      preview.save!
      checksum = Digest::MD5.base64digest(bytes)
      return true if preview.file.attached? && preview.file.blob.checksum == checksum

      preview.file.attach(
        io: StringIO.new(bytes), filename: "#{model.slug}-preview.stl", content_type: "model/stl"
      )
      true
    end
  end
end
