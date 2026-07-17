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
      when "render" then check_render(head)
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

      def check_render(head)
        return nil if head.start_with?("\x89PNG".b) || head.start_with?("\xFF\xD8".b)
        "renders must be PNG or JPEG"
      end
    end
  end
end
