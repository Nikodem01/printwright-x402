require "zip"

module PreviewMeshes
  # Produces an intentionally coarse, open STL for the public viewer. It is
  # useful for judging shape but cannot substitute for the paid mesh: vertices
  # are heavily quantized and the underside is removed so the shell cannot be
  # sliced as a printable solid.
  class Generator
    GRID_DIVISIONS = 32
    HEADER = "PRINTWRIGHT PREVIEW ONLY - OPEN DECIMATED NON-PRINTABLE".b.freeze

    class << self
      def call(bytes:, kind:)
        triangles = kind == "3mf" ? triangles_from_3mf(bytes) : triangles_from_stl(bytes)
        return if triangles.length < 2

        triangles = quantize(triangles)
        triangles = triangles.uniq { |triangle| triangle.sort }
        triangles = open_underside(triangles)
        return if triangles.empty?

        binary_stl(triangles)
      rescue Zip::Error, Nokogiri::XML::SyntaxError, ArgumentError, RangeError
        nil
      end

      private

      def triangles_from_stl(bytes)
        count = bytes.bytesize >= 84 ? bytes.byteslice(80, 4).unpack1("V") : 0
        if count.positive? && bytes.bytesize == 84 + (count * 50)
          return count.times.map do |index|
            bytes.byteslice(84 + (index * 50) + 12, 36).unpack("e9").each_slice(3).to_a
          end
        end

        vertices = bytes.scan(/^\s*vertex\s+([-+\deE.]+)\s+([-+\deE.]+)\s+([-+\deE.]+)/)
                        .map { |point| point.map { |value| Float(value) } }
        vertices.each_slice(3).select { |triangle| triangle.length == 3 }
      end

      def triangles_from_3mf(bytes)
        triangles = []
        Zip::File.open_buffer(StringIO.new(bytes)) do |zip|
          entry = zip.find_entry("3D/3dmodel.model") || zip.glob("3D/*.model").first
          return [] unless entry

          document = Nokogiri::XML(entry.get_input_stream.read) { |config| config.strict.nonet }
          mesh = document.at_xpath("//*[local-name()='mesh']")
          return [] unless mesh

          vertices = mesh.xpath("./*[local-name()='vertices']/*[local-name()='vertex']").map do |vertex|
            %w[x y z].map { |axis| Float(vertex[axis]) }
          end
          triangles = mesh.xpath("./*[local-name()='triangles']/*[local-name()='triangle']").filter_map do |triangle|
            indexes = %w[v1 v2 v3].map { |key| Integer(triangle[key], 10) }
            indexes.map { |index| vertices.fetch(index) }
          rescue IndexError
            nil
          end
        end
        triangles
      end

      def quantize(triangles)
        points = triangles.flatten(1)
        minimums = 3.times.map { |axis| points.map { |point| point[axis] }.min }
        maximums = 3.times.map { |axis| points.map { |point| point[axis] }.max }
        grid = maximums.zip(minimums).map { |high, low| high - low }.max / GRID_DIVISIONS.to_f
        return [] unless grid.positive? && grid.finite?

        triangles.filter_map do |triangle|
          coarse = triangle.map do |point|
            point.each_with_index.map { |coordinate, axis| (((coordinate - minimums[axis]) / grid).round * grid) + minimums[axis] }
          end
          coarse unless normal(coarse).nil?
        end
      end

      def open_underside(triangles)
        minimum = triangles.flatten(1).map { |point| point[2] }.min
        opened = triangles.reject { |triangle| triangle.all? { |point| (point[2] - minimum).abs <= Float::EPSILON } }
        # A mesh without a flat bottom still needs one missing face so even a
        # tiny tetrahedron cannot become a free printable shell.
        opened.length == triangles.length ? triangles.drop(1) : opened
      end

      def binary_stl(triangles)
        body = triangles.map do |triangle|
          [ *normal(triangle), *triangle.flatten ].pack("e12") + [ 0 ].pack("v")
        end.join
        HEADER.ljust(80, "\0") + [ triangles.length ].pack("V") + body
      end

      def normal(triangle)
        left = triangle[1].zip(triangle[0]).map { |to, from| to - from }
        right = triangle[2].zip(triangle[0]).map { |to, from| to - from }
        vector = [
          (left[1] * right[2]) - (left[2] * right[1]),
          (left[2] * right[0]) - (left[0] * right[2]),
          (left[0] * right[1]) - (left[1] * right[0])
        ]
        length = Math.sqrt(vector.sum { |value| value * value })
        return if length <= Float::EPSILON || !length.finite?

        vector.map { |value| value / length }
      end
    end
  end
end
