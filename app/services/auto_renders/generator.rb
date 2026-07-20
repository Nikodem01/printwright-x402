require "open3"
require "tmpdir"

module AutoRenders
  class Generator
    Error = Class.new(StandardError)
    Frame = Data.define(:name, :bytes)

    WIDTH = 800
    HEIGHT = 600
    VIEWS = 12.times.to_h do |index|
      angle = index * 30
      [ format("angle-%03d", angle), angle + 45 ]
    end.freeze
    PNG_SIGNATURE = "\x89PNG\r\n\x1a\n".b.freeze

    class << self
      def call(bytes:, executable: ENV.fetch("OPENSCAD_BIN", "openscad"))
        Dir.mktmpdir("printwright-render-") do |directory|
          source = File.join(directory, "source.stl")
          scene = File.join(directory, "scene.scad")
          File.binwrite(source, bytes)
          File.write(scene, "import(\"source.stl\", convexity=10);\n")

          VIEWS.map do |name, angle|
            output = File.join(directory, "#{name}.png")
            render(executable, scene, output, angle)
            image = File.binread(output)
            validate_png!(image)
            Frame.new(name: name, bytes: image)
          end
        end
      end

      private

      def render(executable, scene, output, angle)
        _stdout, stderr, status = Open3.capture3(
          { "QT_QPA_PLATFORM" => "offscreen" },
          "timeout", "90s", executable, "-q", "--imgsize=#{WIDTH},#{HEIGHT}",
          "--autocenter", "--viewall", "--render", "--projection=o",
          "--camera=0,0,0,65,0,#{angle},0", "--colorscheme=Tomorrow",
          "-o", output, scene
        )
        return if status.success? && File.file?(output)

        detail = stderr.to_s.lines.last.to_s.strip.presence || "renderer exited #{status.exitstatus}"
        raise Error, "OpenSCAD thumbnail failed: #{detail}"
      end

      def validate_png!(bytes)
        width, height = bytes.byteslice(16, 8)&.unpack("NN")
        return if bytes.start_with?(PNG_SIGNATURE) && width == WIDTH && height == HEIGHT

        raise Error, "OpenSCAD returned an invalid #{WIDTH}x#{HEIGHT} PNG"
      end
    end
  end
end
