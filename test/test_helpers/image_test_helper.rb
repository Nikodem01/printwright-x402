# Minimal PNG and JPEG headers at chosen dimensions. The validator reads the
# header and never decodes the image, so a well-formed header is a faithful
# fixture for these checks.
module ImageTestHelper
  def png_bytes(width: 800, height: 600, padding: 0)
    ihdr = [ width, height ].pack("N2") + [ 8, 6, 0, 0, 0 ].pack("C5")
    "\x89PNG\r\n\x1a\n".b +
      [ 13 ].pack("N") + "IHDR".b + ihdr + [ 0 ].pack("N") +
      ("\x00".b * padding)
  end

  def jpeg_bytes(width: 800, height: 600, exif_padding: 0)
    exif = if exif_padding.positive?
      "\xFF\xE1".b + [ exif_padding + 2 ].pack("n") + ("\x00".b * exif_padding)
    else
      "".b
    end
    sof = "\xFF\xC0".b + [ 17 ].pack("n") + [ 8 ].pack("C") +
      [ height, width ].pack("n2") + ("\x00".b * 6)
    "\xFF\xD8".b + exif + sof + "\xFF\xD9".b
  end
end
