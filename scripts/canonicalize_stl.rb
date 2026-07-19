#!/usr/bin/env ruby
# frozen_string_literal: true

# OpenSCAD/CGAL may emit identical triangles in a different order between
# processes. Canonical ordering keeps model hashes stable across regeneration.
ARGV.each do |path|
  bytes = File.binread(path)
  count = bytes.byteslice(80, 4)&.unpack1("V").to_i
  abort "#{path}: expected binary STL" unless count.positive? && bytes.bytesize == 84 + (count * 50)

  triangles = count.times.map do |index|
    values = bytes.byteslice(84 + (index * 50) + 12, 36).unpack("e9")
    vertices = values.each_slice(3).map { |vertex| vertex.map { |value| value.zero? ? 0.0 : value } }
    3.times.map { |rotation| vertices.rotate(rotation) }.min
  end
  triangles.sort_by!(&:flatten)

  body = triangles.map do |vertices|
    left = vertices[1].zip(vertices[0]).map { |to, from| to - from }
    right = vertices[2].zip(vertices[0]).map { |to, from| to - from }
    normal = [
      (left[1] * right[2]) - (left[2] * right[1]),
      (left[2] * right[0]) - (left[0] * right[2]),
      (left[0] * right[1]) - (left[1] * right[0])
    ]
    length = Math.sqrt(normal.sum { |value| value * value })
    normal.map! { |value| value / length }
    [ *normal, *vertices.flatten ].pack("e12") + [ 0 ].pack("v")
  end.join

  header = "Printwright canonical binary STL".b.ljust(80, "\0")
  File.binwrite(path, header + [ triangles.length ].pack("V") + body)
end
