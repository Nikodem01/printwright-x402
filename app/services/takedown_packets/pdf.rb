module TakedownPackets
  class Pdf
    PAGE_WIDTH = 612
    PAGE_HEIGHT = 792

    def self.call(lines)
      content = "BT\n/F1 10 Tf\n50 750 Td\n14 TL\n" +
        lines.flat_map { |line| wrap(line.to_s, 88) }.map { |line| "(#{escape(line)}) Tj T*\n" }.join +
        "ET\n"
      objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 #{PAGE_WIDTH} #{PAGE_HEIGHT}] " \
          "/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
        "<< /Length #{content.bytesize} >>\nstream\n#{content}endstream",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"
      ]
      document = +"%PDF-1.4\n%\xE2\xE3\xCF\xD3\n".b
      offsets = objects.map.with_index(1) do |object, number|
        document.bytesize.tap { document << "#{number} 0 obj\n#{object}\nendobj\n" }
      end
      xref = document.bytesize
      document << "xref\n0 #{objects.length + 1}\n0000000000 65535 f \n"
      offsets.each { |offset| document << format("%010d 00000 n \n", offset) }
      document << "trailer\n<< /Size #{objects.length + 1} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
      document
    end

    class << self
      private

      def wrap(text, width)
        return [ "" ] if text.empty?

        text.scan(/.{1,#{width}}(?:\s+|\z)/).map(&:strip)
      end

      def escape(text)
        text.encode("Windows-1252", invalid: :replace, undef: :replace, replace: "?")
            .gsub(/[\\()]/) { |character| "\\#{character}" }
      end
    end
  end
end
