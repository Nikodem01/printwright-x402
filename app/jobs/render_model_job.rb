class RenderModelJob < ApplicationJob
  AUTO_PREFIX = "printwright-auto-render-"

  queue_as :default

  def perform(model_id, replace_existing = false)
    model = Model3d.find(model_id)
    source = model.printable_files.find { |file| file.kind == "stl" && file.file.attached? }
    return false unless source

    frames = AutoRenders::Generator.call(bytes: source.file.download)
    remove_existing_renders(model, replace_existing)
    position = model.model_files.maximum(:position).to_i + 1
    frames.each_with_index do |frame, index|
      render = model.model_files.create!(kind: "render", position: position + index)
      render.file.attach(
        io: StringIO.new(frame.bytes), filename: "#{AUTO_PREFIX}#{frame.name}.png", content_type: "image/png"
      )
    end
    true
  end

  private

  def remove_existing_renders(model, replace_existing)
    model.model_files.select do |file|
      next false unless file.kind == "render"

      replace_existing || (file.file.attached? && file.file.filename.to_s.start_with?(AUTO_PREFIX))
    end.each(&:destroy!)
  end
end
