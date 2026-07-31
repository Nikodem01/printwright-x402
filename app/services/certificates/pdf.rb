require "prawn"
require "rqrcode"

# We use the built-in AFM fonts deliberately (no font file to vendor or keep in
# sync) and handle their Windows-1252 limit ourselves in #drawable, so Prawn's
# standing warning about it is noise on every render.
Prawn::Fonts::AFM.hide_m17n_warning = true

module Certificates
  # A designed, self-contained PDF license certificate for the paid deliverable.
  # Pure Ruby (Prawn) — no headless browser — so it renders identically wherever
  # the app runs. On-brand with the web certificate: monospaced cert id as the
  # focal point, hairline-ruled facts, and the on-chain commitment in the
  # issuance green. It shows the same reveal a verifier checks: the commitment
  # that is public plus the certificate that is not.
  class Pdf
    INK = "141916".freeze
    MUTED = "566059".freeze
    RULE = "cbd3ce".freeze
    CHAIN = "1b5e45".freeze

    def self.render(license, verify_url:)
      new(license, verify_url).render
    end

    def initialize(license, verify_url)
      @license = license
      @verify_url = verify_url
      @cert = license.cert_json || {}
      @bundle = Certificates::Bundle.for(license)
      @offer = license.purchase.license_offer
      @model = @offer.model3d
      @sandbox = license.purchase.sandbox?
    end

    def render
      doc = Prawn::Document.new(page_size: "A4", margin: 56)
      doc.font "Helvetica"
      top = doc.cursor
      qr_code(doc, top)
      header(doc, top)
      statement(doc)
      facts(doc)
      commitment_note(doc)
      footer(doc)
      doc.render
    end

    private

    def qr_code(doc, top)
      png = RQRCode::QRCode.new(@verify_url).as_png(size: 220, border_modules: 2)
      doc.image StringIO.new(png.to_blob), at: [ doc.bounds.width - 80, top ], width: 80
    end

    # Header text lives in a left column that stops short of the QR, and the
    # body then drops below the whole header block so nothing overlaps.
    def header(doc, top)
      width = doc.bounds.width - 96
      color(doc, MUTED)
      doc.font("Helvetica", style: :bold, size: 8) { doc.text_box eyebrow, at: [ 0, top ], width: width, character_spacing: 1.6 }
      color(doc, INK)
      doc.font("Courier", size: 22) do
        doc.text_box @license.cert_id, at: [ 0, top - 16 ], width: width, overflow: :shrink_to_fit, single_line: true
      end
      color(doc, MUTED)
      doc.font("Helvetica", size: 9.5) { doc.text_box subtitle, at: [ 0, top - 46 ], width: width, height: 28 }
      doc.move_cursor_to top - 96
    end

    def statement(doc)
      color(doc, INK)
      doc.font("Helvetica", size: 11) { doc.text statement_text, leading: 3 }
      doc.move_down 18
    end

    def facts(doc)
      fact(doc, "Model hash", @cert["model_hash"])
      fact(doc, @sandbox ? "Fake transaction" : "Payment tx", @cert["payment_tx"])
      fact(doc, "Terms hash", @cert["terms_hash"])
      fact(doc, "Issued", @cert["issued_at"])
      fact(doc, "Commitment (on-chain)", @bundle["commitment"], chain: true)
      if @license.anchored? && !@sandbox
        fact(doc, "HCS anchor", "topic #{@license.hcs_topic_id} · sequence #{@license.hcs_sequence_number}", chain: true)
      end
    end

    def fact(doc, label, value, chain: false)
      value = value.to_s
      top = doc.cursor
      value_width = doc.bounds.width - 116
      color(doc, MUTED)
      doc.font("Helvetica", size: 8) { doc.text_box label.upcase, at: [ 0, top ], width: 104, character_spacing: 0.4 }
      color(doc, chain ? CHAIN : INK)
      doc.font "Courier"
      doc.font_size 9.5
      height = doc.height_of(value, width: value_width)
      doc.text_box value, at: [ 116, top ], width: value_width
      doc.font "Helvetica"
      doc.font_size 11
      doc.move_cursor_to(top - [ height, 11 ].max - 8)
      color(doc, RULE)
      doc.stroke_color RULE
      doc.stroke_horizontal_rule
      doc.move_down 8
    end

    def commitment_note(doc)
      doc.move_down 4
      color(doc, MUTED)
      doc.font("Helvetica", size: 8.5) do
        doc.text @sandbox ? sandbox_note : commitment_text, leading: 2, style: :italic
      end
      doc.move_down 16
    end

    def footer(doc)
      color(doc, RULE)
      doc.stroke_color RULE
      doc.stroke_horizontal_rule
      doc.move_down 10
      color(doc, MUTED)
      doc.font("Helvetica", size: 8.5) do
        doc.text @sandbox ? "Inspect this local simulation:" : "Verify independently — none of these require trusting Printwright:"
      end
      doc.move_down 4
      color(doc, INK)
      doc.font("Courier", size: 8) do
        doc.text "live check: #{@verify_url}"
        if @license.anchored? && !@sandbox
          doc.text "mirror node: #{@bundle.dig('hedera', 'mirror_url')}"
        end
      end
    end

    def eyebrow
      @sandbox ? "SANDBOX REHEARSAL CERTIFICATE" : "LICENSE CERTIFICATE"
    end

    def subtitle
      if @sandbox
        "SANDBOX SIMULATION — not a Hedera record, payment, or printable-model license."
      else
        "Printwright — the 3D model store for agents. Anchored to Hedera as an opaque commitment."
      end
    end

    def statement_text
      title = drawable(@model.title)
      designer = drawable(@model.designer.display_name)
      if @sandbox
        "This locally simulates license ##{@license.serial} for #{title} by #{designer}. " \
          "It grants no rights and certifies no payment or license."
      elsif @offer.kind == "personal"
        "This certifies personal license ##{@license.serial} for #{title}, granted by #{designer}. " \
          "It permits unlimited physical prints for personal, non-commercial use."
      else
        "This certifies commercial unit ##{@license.serial} of #{title}, granted by #{designer}. " \
          "It permits one physical print for commercial sale."
      end
    end

    def commitment_text
      "Only this opaque commitment is published on Hedera — SHA-256 of the certificate and a private " \
        "blinding nonce. This sheet is the private preimage; revealing it lets anyone recompute the hash " \
        "and confirm it against the public mirror node."
    end

    def sandbox_note
      "This is a local rehearsal. No commitment was published to Hedera and no funds moved."
    end

    # A model title and a studio name are chosen by people, and Prawn's built-in
    # fonts speak only Windows-1252 — an accent is fine, a Han character raises.
    # A certificate must render for every designer we have, so keep whatever
    # that set can represent (é, ø, £) and transliterate the rest to its nearest
    # ASCII, falling back to "?" only when there is no sensible stand-in. The
    # facts a verifier actually recomputes — cert id, hashes, tx, URLs — are
    # ASCII by construction and pass through untouched.
    def drawable(text)
      text.to_s.each_char.map do |char|
        char.encode(Encoding::Windows_1252)
        char
      rescue Encoding::UndefinedConversionError
        ActiveSupport::Inflector.transliterate(char, "?")
      end.join
    end

    def color(doc, hex)
      doc.fill_color hex
    end
  end
end
