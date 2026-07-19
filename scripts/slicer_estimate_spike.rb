#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"

root = File.expand_path("..", __dir__)
executable = ENV.fetch("PRUSA_SLICER_BIN", "prusa-slicer")
inputs = if ARGV.any?
  ARGV.map { |path| File.expand_path(path) }
else
  %w[calibration-cube phone-stand hex-organizer].map do |name|
    File.join(root, "db/seed_assets/#{name}.stl")
  end
end

profile = {
  name: ENV.fetch("PROFILE_NAME", "baseline"),
  nozzle_mm: 0.4,
  layer_mm: ENV.fetch("LAYER_MM", "0.2").to_f,
  filament_mm: 1.75,
  filament_density_g_cm3: 1.24,
  infill: ENV.fetch("INFILL", "15%"),
  perimeters: ENV.fetch("PERIMETERS", "2").to_i,
  supports: false,
  bed_mm: [ 220, 220 ]
}

version_output, version_error, version_status = Open3.capture3(executable, "--help")
abort(version_error) unless version_status.success?

def seconds_for(text)
  match = text.match(/(?:(\d+)h )?(?:(\d+)m )?(\d+)s/)
  return unless match

  (match[1].to_i * 3600) + (match[2].to_i * 60) + match[3].to_i
end

results = Dir.mktmpdir("printwright-slicer-spike-") do |directory|
  inputs.map.with_index do |input, index|
    output = File.join(directory, "#{index}.gcode")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    stdout, stderr, status = Open3.capture3(
      executable, "--export-gcode", "--output", output,
      "--layer-height", profile.fetch(:layer_mm).to_s,
      "--first-layer-height", profile.fetch(:layer_mm).to_s,
      "--nozzle-diameter", profile.fetch(:nozzle_mm).to_s,
      "--filament-diameter", profile.fetch(:filament_mm).to_s,
      "--filament-density", profile.fetch(:filament_density_g_cm3).to_s,
      "--fill-density", profile.fetch(:infill),
      "--perimeters", profile.fetch(:perimeters).to_s,
      "--bed-shape", "0x0,220x0,220x220,0x220", "--center", "110,110",
      "--threads", "2", input
    )
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    abort("#{File.basename(input)}: #{stderr.empty? ? stdout : stderr}") unless status.success?

    gcode = File.binread(output)
    time_text = gcode[/^; estimated printing time \(normal mode\) = (.+)$/, 1]
    {
      model: File.basename(input),
      slice_seconds: elapsed.round(3),
      estimated_print: time_text,
      estimated_print_seconds: seconds_for(time_text.to_s),
      filament_mm: gcode[/^; filament used \[mm\] = ([\d.]+)$/, 1]&.to_f,
      filament_cm3: gcode[/^; filament used \[cm3\] = ([\d.]+)$/, 1]&.to_f,
      filament_g: gcode[/^; total filament used \[g\] = ([\d.]+)$/, 1]&.to_f,
      gcode_bytes: gcode.bytesize
    }
  end
end

puts JSON.pretty_generate(
  slicer: version_output.lines.first.to_s.strip,
  profile: profile,
  results: results
)
