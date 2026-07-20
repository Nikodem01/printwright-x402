namespace :auto_renders do
  desc "Regenerate twelve OpenSCAD turntable frames for published STL models (REPLACE=1 removes supplied renders)"
  task rerender: :environment do
    replace = ENV["REPLACE"] == "1"
    Model3d.published.find_each do |model|
      next unless model.printable_files.any? { |file| file.kind == "stl" && file.file.attached? }

      RenderModelJob.perform_now(model.id, replace)
      puts "#{model.slug}: twelve turntable frames"
    end
  end
end
