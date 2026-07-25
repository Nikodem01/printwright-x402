module Models
  # A published listing has to show the buyer something — it is the only look
  # they get before paying. A designer's own image always wins; otherwise one
  # frame is rendered from the printable bundle *before* the listing goes live,
  # rather than by the job that follows it, so a live card is never blank.
  # RenderModelJob then replaces it with the full turntable set.
  class CoverImage
    # => true when the listing has an image a buyer can see, else false
    def self.ensure!(model)
      return true if model.render_files.any? { |file| file.file.attached? }

      source = model.printable_files.find { |file| file.kind == "stl" && file.file.attached? }
      return false unless source

      frame = AutoRenders::Generator.call(
        bytes: source.file.download,
        views: AutoRenders::Generator::COVER_VIEW,
        timeout: AutoRenders::Generator::COVER_TIMEOUT
      ).first
      return false unless frame

      render = model.model_files.create!(kind: "render", position: model.model_files.maximum(:position).to_i + 1)
      render.file.attach(
        io: StringIO.new(frame.bytes), content_type: "image/png",
        filename: "#{RenderModelJob::AUTO_PREFIX}#{frame.name}.png"
      )
      true
    rescue AutoRenders::Generator::Error
      false
    end
  end
end
