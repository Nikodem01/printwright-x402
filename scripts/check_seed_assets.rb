#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"

ROOT = File.expand_path("..", __dir__)
ASSET_DIR = File.join(ROOT, "db", "seed_assets")
MANIFEST = YAML.safe_load_file(File.join(ASSET_DIR, "provenance.yml"))
TOLERANCE_MM = 0.35

errors = []
models = MANIFEST.fetch("models")

models.each do |asset_name, provenance|
  stl_path = File.join(ASSET_DIR, "#{asset_name}.stl")
  png_path = File.join(ASSET_DIR, "#{asset_name}.png")

  unless File.file?(stl_path) && File.file?(png_path)
    errors << "#{asset_name}: STL and PNG are both required"
    next
  end

  stl_bytes = File.binread(stl_path)
  binary_triangle_count = stl_bytes.bytesize >= 84 ? stl_bytes.byteslice(80, 4).unpack1("V") : 0
  if binary_triangle_count.positive? && stl_bytes.bytesize == 84 + (binary_triangle_count * 50)
    triangles = binary_triangle_count.times.map do |index|
      stl_bytes.byteslice(84 + (index * 50) + 12, 36).unpack("e9").each_slice(3).to_a
    end
  else
    triangles = []
    vertices = []
    stl_bytes.each_line do |line|
      match = line.match(/^\s*vertex\s+([-+\deE.]+)\s+([-+\deE.]+)\s+([-+\deE.]+)/)
      next unless match

      vertices << match.captures.map { |number| Float(number) }
      next unless vertices.length == 3

      triangles << vertices
      vertices = []
    end
  end

  errors << "#{asset_name}: expected at least 20 triangles" if triangles.length < 20
  points = triangles.flatten(1)
  next if points.empty?

  minimums = 3.times.map { |axis| points.map { |point| point[axis] }.min }
  maximums = 3.times.map { |axis| points.map { |point| point[axis] }.max }
  dimensions = 3.times.map { |axis| maximums[axis] - minimums[axis] }
  expected = provenance.fetch("dimensions_mm")
  dimensions.zip(expected).each_with_index do |(actual, declared), axis|
    next if (actual - declared).abs <= TOLERANCE_MM

    errors << "#{asset_name}: axis #{axis} is #{actual.round(2)} mm, manifest says #{declared} mm"
  end
  errors << "#{asset_name}: geometry extends below the print bed" if minimums[2] < -0.02

  edges = Hash.new(0)
  triangles.each do |triangle|
    quantized = triangle.map { |point| point.map { |coordinate| (coordinate * 100_000).round } }
    area_vector = [
      (quantized[1][1] - quantized[0][1]) * (quantized[2][2] - quantized[0][2]) -
        (quantized[1][2] - quantized[0][2]) * (quantized[2][1] - quantized[0][1]),
      (quantized[1][2] - quantized[0][2]) * (quantized[2][0] - quantized[0][0]) -
        (quantized[1][0] - quantized[0][0]) * (quantized[2][2] - quantized[0][2]),
      (quantized[1][0] - quantized[0][0]) * (quantized[2][1] - quantized[0][1]) -
        (quantized[1][1] - quantized[0][1]) * (quantized[2][0] - quantized[0][0])
    ]
    errors << "#{asset_name}: degenerate triangle" if area_vector.all?(&:zero?)
    [ [ 0, 1 ], [ 1, 2 ], [ 2, 0 ] ].each do |from, to|
      edges[[ quantized[from], quantized[to] ].sort] += 1
    end
  end
  open_edges = edges.count { |_edge, uses| uses != 2 }
  errors << "#{asset_name}: #{open_edges} non-manifold/open edges" unless open_edges.zero?

  png_header = File.binread(png_path, 24)
  if png_header.byteslice(0, 8) != "\x89PNG\r\n\x1a\n".b
    errors << "#{asset_name}: render is not a PNG"
  else
    width, height = png_header.byteslice(16, 8).unpack("NN")
    errors << "#{asset_name}: render must be 800x600 (found #{width}x#{height})" unless [ width, height ] == [ 800, 600 ]
  end

  %w[slug orientation notes].each do |field|
    errors << "#{asset_name}: provenance #{field} is required" if provenance[field].to_s.strip.empty?
  end
end

actual_assets = Dir[File.join(ASSET_DIR, "*.stl")].map { |path| File.basename(path, ".stl") }.sort
errors << "manifest/STL catalog mismatch" unless actual_assets == models.keys.sort
errors << "catalog license must be CC0-1.0" unless MANIFEST["catalog_license"] == "CC0-1.0"
errors << "catalog source is missing" unless File.file?(File.join(ROOT, MANIFEST.fetch("source")))

if errors.any?
  warn errors.join("\n")
  exit 1
end

puts "Seed assets valid: #{models.length} provenance records, manifold STLs, declared bounds, 800x600 renders."
