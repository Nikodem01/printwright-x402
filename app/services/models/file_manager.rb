module Models
  class FileManager
    class Error < StandardError; end

    def self.destroy!(model:, file:)
      printable_changed = false
      ModelFile.transaction do
        model.lock!
        file.lock!
        guard_printable_change!(model, file)
        printable_changed = file.printable?
        file.destroy!
        resequence!(model.model_files.lock.order(:position, :id).to_a)
      end
      AnalysisQueue.call(model) if printable_changed
    end

    def self.move!(model:, file:, direction:)
      direction = direction.to_s
      raise Error, "Choose move up or move down." unless direction.in?(%w[up down])

      ModelFile.transaction do
        model.lock!
        files = model.model_files.lock.order(:position, :id).to_a
        file = files.find { |candidate| candidate.id == file.id } or raise ActiveRecord::RecordNotFound
        guard_printable_change!(model, file)
        peers = files.select { |candidate| peer_group(candidate) == peer_group(file) }
        index = peers.index(file)
        target = direction == "up" ? index - 1 : index + 1
        return file unless target.between?(0, peers.length - 1)

        positions = peers.map(&:position).sort
        peers[index], peers[target] = peers[target], peers[index]
        peers.zip(positions).each { |candidate, position| candidate.update_columns(position: position) }
      end
      file
    end

    def self.feature!(model:, file:)
      raise Error, "Only a render image can be featured." unless file.kind == "render"

      ModelFile.transaction do
        model.lock!
        renders = model.model_files.where(kind: "render").lock.order(:position, :id).to_a
        file = renders.find { |candidate| candidate.id == file.id } or raise ActiveRecord::RecordNotFound
        positions = renders.map(&:position).sort
        ([ file ] + (renders - [ file ])).zip(positions).each do |candidate, position|
          candidate.update_columns(position: position)
        end
      end
      file
    end

    def self.guard_printable_change!(model, file)
      return unless file.printable? && !model.draft?

      raise Error, "The certified printable bundle is frozen. Publish an additive version instead."
    end
    private_class_method :guard_printable_change!

    def self.peer_group(file)
      file.printable? ? :printable : file.kind
    end
    private_class_method :peer_group

    def self.resequence!(files)
      files.each_with_index { |file, position| file.update_columns(position: position) }
    end
    private_class_method :resequence!
  end
end
