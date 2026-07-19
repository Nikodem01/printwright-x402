require "digest"
require "zip"

module MeshAnalysis
  class Analyzer
    Result = Data.define(:digest, :geometry_hash, :errors, :files)

    MIN_WALL_MM = 0.4
    MAX_TRIANGLES = 100_000
    THICKNESS_SAMPLES = 160
    POINT_SCALE = 100_000
    RAY_EPSILON = 0.00001
    SUPPORTED_KINDS = %w[stl 3mf].freeze
    EDGES = [ [ 0, 1 ], [ 1, 2 ], [ 2, 0 ] ].freeze
    UNIT_SCALE = {
      "micron" => 0.001,
      "millimeter" => 1.0,
      "centimeter" => 10.0,
      "inch" => 25.4,
      "foot" => 304.8,
      "meter" => 1000.0
    }.freeze

    class << self
      def call(model_files)
        inputs = attached_inputs(model_files)
        digest = bundle_digest(inputs)
        errors = []
        reports = []
        geometry = []

        inputs.each do |input|
          filename = input.fetch(:filename)
          unless SUPPORTED_KINDS.include?(input.fetch(:kind))
            errors << "#{filename}: automatic mesh validation supports STL and 3MF; attach one of those formats before publishing"
            next
          end

          triangles = triangles_for(input)
          report, file_errors = inspect_triangles(triangles)
          reports << report.merge("filename" => filename, "kind" => input.fetch(:kind))
          errors.concat(file_errors.map { |message| "#{filename}: #{message}" })
          geometry.concat(triangles)
        rescue Zip::Error, Nokogiri::XML::SyntaxError, ArgumentError, KeyError, RangeError => error
          errors << "#{filename}: could not read mesh (#{error.class.name.demodulize})"
        end

        Result.new(
          digest: digest,
          geometry_hash: geometry.empty? ? nil : normalized_geometry_hash(geometry),
          errors: errors,
          files: reports
        )
      end

      def bundle_digest(model_files)
        inputs = model_files.first.is_a?(Hash) ? model_files : attached_inputs(model_files)
        digest = Digest::SHA256.new
        inputs.sort_by { |input| input.fetch(:filename) }.each { |input| digest.update(input.fetch(:bytes)) }
        "sha256:#{digest.hexdigest}"
      end

      private

      def attached_inputs(model_files)
        model_files.select { |model_file| model_file.file.attached? }.map do |model_file|
          {
            kind: model_file.kind,
            filename: model_file.file.filename.to_s,
            bytes: model_file.file.download
          }
        end
      end

      def triangles_for(input)
        input.fetch(:kind) == "3mf" ? triangles_from_3mf(input.fetch(:bytes)) : triangles_from_stl(input.fetch(:bytes))
      end

      def triangles_from_stl(bytes)
        count = bytes.bytesize >= 84 ? bytes.byteslice(80, 4).unpack1("V") : 0
        if count.positive? && bytes.bytesize == 84 + (count * 50)
          raise RangeError, "mesh exceeds triangle limit" if count > MAX_TRIANGLES

          return count.times.map do |index|
            bytes.byteslice(84 + (index * 50) + 12, 36).unpack("e9").each_slice(3).to_a
          end
        end

        vertices = bytes.scan(/^\s*vertex\s+([-+\deE.]+)\s+([-+\deE.]+)\s+([-+\deE.]+)/)
                        .map { |point| point.map { |value| Float(value) } }
        triangles = vertices.each_slice(3).select { |triangle| triangle.length == 3 }
        raise RangeError, "mesh exceeds triangle limit" if triangles.length > MAX_TRIANGLES

        triangles
      end

      def triangles_from_3mf(bytes)
        triangles = []
        Zip::File.open_buffer(StringIO.new(bytes)) do |zip|
          entry = zip.find_entry("3D/3dmodel.model") || zip.glob("3D/*.model").first
          raise ArgumentError, "3D model part is missing" unless entry

          document = Nokogiri::XML(entry.get_input_stream.read) { |config| config.strict.nonet }
          scale = UNIT_SCALE.fetch(document.root["unit"].presence || "millimeter")
          document.xpath("//*[local-name()='mesh']").each do |mesh|
            vertices = mesh.xpath("./*[local-name()='vertices']/*[local-name()='vertex']").map do |vertex|
              %w[x y z].map { |axis| Float(vertex[axis]) * scale }
            end
            mesh.xpath("./*[local-name()='triangles']/*[local-name()='triangle']").each do |triangle|
              indexes = %w[v1 v2 v3].map { |key| Integer(triangle[key], 10) }
              triangles << indexes.map { |index| vertices.fetch(index) }
              raise RangeError, "mesh exceeds triangle limit" if triangles.length > MAX_TRIANGLES
            end
          end
        end
        triangles
      end

      def inspect_triangles(triangles)
        errors = []
        errors << "contains fewer than four triangles" if triangles.length < 4
        non_finite = triangles.flatten(1).count { |point| point.any? { |coordinate| !coordinate.finite? } }
        errors << "contains #{non_finite} non-finite vertices" if non_finite.positive?
        if non_finite.positive?
          return [
            {
              "triangle_count" => triangles.length,
              "degenerate_triangles" => nil,
              "boundary_edges" => nil,
              "non_manifold_edges" => nil,
              "estimated_wall_mm" => nil
            },
            errors
          ]
        end

        edges = Hash.new(0)
        degenerate = 0
        triangles.each do |triangle|
          points = triangle.map { |point| point.map { |coordinate| (coordinate * POINT_SCALE).round } }
          if cross(subtract(points[1], points[0]), subtract(points[2], points[0])).all?(&:zero?)
            degenerate += 1
            next
          end
          EDGES.each { |from, to| edges[[ points[from], points[to] ].sort] += 1 }
        end
        boundary_edges = edges.count { |_edge, uses| uses == 1 }
        non_manifold_edges = edges.count { |_edge, uses| uses > 2 }
        errors << "contains #{degenerate} degenerate triangles" if degenerate.positive?
        errors << "is open (#{boundary_edges} boundary edges)" if boundary_edges.positive?
        errors << "is non-manifold (#{non_manifold_edges} edges are shared by more than two faces)" if non_manifold_edges.positive?

        thickness = if errors.empty?
          estimated_thickness(triangles)
        end
        if thickness && thickness < MIN_WALL_MM
          errors << "estimated wall thickness is #{thickness.round(3)} mm; minimum is #{MIN_WALL_MM} mm"
        end

        [
          {
            "triangle_count" => triangles.length,
            "degenerate_triangles" => degenerate,
            "boundary_edges" => boundary_edges,
            "non_manifold_edges" => non_manifold_edges,
            "estimated_wall_mm" => thickness&.round(4)
          },
          errors
        ]
      end

      def normalized_geometry_hash(triangles)
        points = triangles.flatten(1)
        minimums = 3.times.map { |axis| points.map { |point| point[axis] }.min }
        canonical = triangles.map do |triangle|
          triangle.map do |point|
            point.each_with_index.map { |coordinate, axis| ((coordinate - minimums[axis]) * POINT_SCALE).round }
          end.sort
        end.sort
        encoded = canonical.map do |triangle|
          triangle.map { |point| point.join(",") }.join(";")
        end.join("|")
        "sha256:#{Digest::SHA256.hexdigest(encoded)}"
      end

      def estimated_thickness(triangles)
        stride = [ triangles.length.fdiv(THICKNESS_SAMPLES), 1 ].max
        sample_count = [ triangles.length, THICKNESS_SAMPLES ].min
        distances = sample_count.times.filter_map do |index|
          triangle = triangles[(index * stride).floor]
          normal = unit_normal(triangle)
          next unless normal

          origin = 3.times.map { |axis| triangle.sum { |point| point[axis] } / 3.0 }
          [ normal, normal.map(&:-@) ].filter_map do |direction|
            triangles.filter_map { |target| ray_distance(origin, direction, target) }.min
          end.min
        end
        sorted = distances.sort
        # A lone ray can graze a nearby concavity and report a near-zero
        # intersection that is not wall thickness. Require repeated evidence
        # while retaining sensitivity on small meshes (three samples).
        index = [ ((sorted.length - 1) * 0.1).floor, 2 ].max
        sorted[[ index, sorted.length - 1 ].min]
      end

      def ray_distance(origin, direction, triangle)
        edge_one = subtract(triangle[1], triangle[0])
        edge_two = subtract(triangle[2], triangle[0])
        h = cross(direction, edge_two)
        determinant = dot(edge_one, h)
        return if determinant.abs < RAY_EPSILON

        inverse = 1.0 / determinant
        s = subtract(origin, triangle[0])
        u = inverse * dot(s, h)
        return if u < 0.0 || u > 1.0

        q = cross(s, edge_one)
        v = inverse * dot(direction, q)
        return if v < 0.0 || (u + v) > 1.0

        distance = inverse * dot(edge_two, q)
        distance if distance > RAY_EPSILON
      end

      def unit_normal(triangle)
        vector = cross(subtract(triangle[1], triangle[0]), subtract(triangle[2], triangle[0]))
        length = Math.sqrt(dot(vector, vector))
        return if length <= Float::EPSILON || !length.finite?

        vector.map { |value| value / length }
      end

      def subtract(left, right)
        left.zip(right).map { |a, b| a - b }
      end

      def cross(left, right)
        [
          (left[1] * right[2]) - (left[2] * right[1]),
          (left[2] * right[0]) - (left[0] * right[2]),
          (left[0] * right[1]) - (left[1] * right[0])
        ]
      end

      def dot(left, right)
        left.zip(right).sum { |a, b| a * b }
      end
    end
  end
end
