require "zip"

module Uploads
  # Content checks for designer uploads — the errors are written for the
  # designer, not the log. A file is judged by its BYTES, never its name:
  #   stl    binary (84 + 50n bytes exactly) or ASCII ("solid" ... "endsolid")
  #   3mf    a real zip whose declared uncompressed size stays sane (bomb guard)
  #   step   ISO-10303 header
  #   render PNG or JPEG magic
  class Validator
    mattr_accessor :max_bytes, default: 50.megabytes
    mattr_accessor :max_3mf_uncompressed, default: 200.megabytes
    mattr_accessor :max_3mf_entries, default: 200
    # A render is the only look a buyer gets before paying, so it has to be
    # large enough to judge and small enough to actually load on a catalog
    # card. Our own auto-renders are 800x600.
    mattr_accessor :max_render_bytes, default: 8.megabytes
    mattr_accessor :min_render_width, default: 640
    mattr_accessor :min_render_height, default: 480
    mattr_accessor :max_render_edge, default: 8192

    # Frame markers carrying the image size; 0xC4/0xC8/0xCC are tables, not frames.
    SOF_MARKERS = ((0xC0..0xCF).to_a - [ 0xC4, 0xC8, 0xCC ]).freeze
    # Markers that stand alone, with no length field following them.
    STANDALONE_MARKERS = ([ 0x01, 0xD8, 0xD9 ] + (0xD0..0xD7).to_a).freeze

    # => nil when acceptable, else a designer-readable reason
    def self.reason_to_reject(upload, kind:)
      size = upload.size
      return "#{upload.original_filename}: empty file" if size.to_i.zero?
      return "#{upload.original_filename}: larger than #{max_bytes / 1.megabyte} MB" if size > max_bytes

      head = read_head(upload, 512)
      case kind
      when "stl"    then check_stl(upload, head, size)
      when "3mf"    then check_3mf(upload, head)
      when "step"   then check_step(head)
      when "render" then check_render(upload, head, size)
      else "#{upload.original_filename}: unsupported file kind #{kind}"
      end
    end

    class << self
      private

      def read_head(upload, bytes)
        upload.rewind
        head = upload.read(bytes).to_s
        upload.rewind
        head
      end

      def check_stl(upload, head, size)
        return nil if head.start_with?("solid") # ASCII STL
        # binary STL: 80-byte header + uint32 count + 50 bytes per triangle
        return "not an STL file (bad header and not ASCII)" if size < 84
        upload.rewind
        header = upload.read(84)
        upload.rewind
        count = header[80, 4].unpack1("V")
        expected = 84 + 50 * count
        size == expected ? nil : "not a valid STL (declares #{count} triangles, size mismatch)"
      end

      def check_3mf(upload, head)
        return "not a 3MF (not a zip archive)" unless head.start_with?("PK\x03\x04")
        entries = 0
        total = 0
        upload.rewind
        Zip::File.open_buffer(StringIO.new(upload.read)) do |zip|
          zip.each do |entry|
            entries += 1
            total += entry.size
            return "3MF has too many entries" if entries > max_3mf_entries
            return "3MF expands too large (#{total / 1.megabyte} MB+)" if total > max_3mf_uncompressed
          end
        end
        upload.rewind
        nil
      rescue Zip::Error
        "not a readable 3MF archive"
      end

      def check_step(head)
        head.include?("ISO-10303") ? nil : "not a STEP file (no ISO-10303 header)"
      end

      def check_render(upload, head, size)
        png = head.start_with?("\x89PNG".b)
        return "renders must be PNG or JPEG" unless png || head.start_with?("\xFF\xD8".b)

        name = upload.original_filename
        if size > max_render_bytes
          return "#{name}: image is larger than #{max_render_bytes / 1.megabyte} MB — export it smaller so catalog pages stay loadable"
        end

        width, height = png ? png_dimensions(head) : jpeg_dimensions(upload)
        return "#{name}: could not read the image size from this file" unless width && height

        if width < min_render_width || height < min_render_height
          "#{name}: #{width}×#{height} is too small — buyers choose from this image, so use at least " \
            "#{min_render_width}×#{min_render_height}"
        elsif width > max_render_edge || height > max_render_edge
          "#{name}: #{width}×#{height} is too large — keep each side under #{max_render_edge} pixels"
        end
      end

      def png_dimensions(head)
        return nil unless head.bytesize >= 24 && head.byteslice(12, 4) == "IHDR".b

        head.byteslice(16, 8).unpack("N2")
      end

      # Walks the JPEG segment chain to the frame header. The size cap above has
      # already bounded how much this reads.
      def jpeg_dimensions(upload)
        upload.rewind
        bytes = upload.read.to_s
        upload.rewind

        offset = 2
        while offset + 9 < bytes.bytesize
          unless bytes.getbyte(offset) == 0xFF
            offset += 1
            next
          end

          marker = bytes.getbyte(offset + 1)
          if STANDALONE_MARKERS.include?(marker) || marker == 0xFF
            offset += 2
            next
          end
          return bytes.byteslice(offset + 5, 4).unpack("n2").reverse if SOF_MARKERS.include?(marker)

          length = bytes.byteslice(offset + 2, 2).unpack1("n").to_i
          break if length < 2

          offset += 2 + length
        end
        nil
      end
    end
  end
end
