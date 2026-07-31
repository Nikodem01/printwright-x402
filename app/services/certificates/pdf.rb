require "prawn"
require "rqrcode"

# We use the built-in AFM fonts deliberately (no font file to vendor or keep in
# sync) and handle their Windows-1252 limit ourselves in #drawable, so Prawn's
# standing warning about it is noise on every render.
Prawn::Fonts::AFM.hide_m17n_warning = true

module Certificates
  # A designed, self-contained PDF license certificate for the paid deliverable.
  # Pure Ruby (Prawn) — no headless browser — so it renders identically wherever
  # the app runs. Page 1 is the on-brand summary; the appendix pages make the
  # document self-contained: the exact canonical certificate JSON, the blinding
  # nonce, the commitment formula, every hash with the inputs needed to
  # recompute it, the public Hedera evidence URLs, and the full governing
  # license text. A stranger holding only this PDF (plus the files in the same
  # ZIP) can reproduce every hash and check the commitment against the public
  # mirror node without trusting Printwright.
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
      appendix(doc)
      license_text_pages(doc)
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
      fact(doc, "License", permissions_line)
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
        unless @sandbox
          if (tx_url = Hedera::Network.transaction_url(@cert["payment_tx"]))
            doc.text "payment:    #{tx_url}"
          end
          if @license.anchored?
            doc.text "mirror:     #{@bundle.dig('hedera', 'mirror_url')}"
            doc.text "topic:      https://hashscan.io/#{Hedera::Network.name}/topic/#{@license.hcs_topic_id}"
          end
        end
      end
    end

    # ---- Appendix: everything needed to reproduce every hash in this PDF ----

    def appendix(doc)
      doc.start_new_page
      appendix_heading(doc, "REPRODUCE THIS CERTIFICATE")
      body(doc, "This appendix is the private preimage of the on-chain commitment. Every value " \
        "below can be recomputed from the inputs printed here and the files delivered in the " \
        "same ZIP — no Printwright service is required. Keep it private: revealing it proves " \
        "the grant; publishing it publishes the grant.")

      section(doc, "1 · Canonical certificate (RFC 8785 JCS)")
      body(doc, "The exact canonical JSON the commitment is computed over. The machine-readable " \
        "copy of this preimage is proof-bundle.json in the delivered ZIP; the same JSON is served " \
        "by the certificate API for as long as Printwright exists.")
      mono_block(doc, Commitment.canonical(@cert))

      section(doc, "2 · Blinding nonce (hex)")
      body(doc, "32 random bytes, hex-encoded. Decoded to raw bytes before hashing. The nonce is " \
        "what keeps the on-chain commitment opaque: without it nobody can test guesses against " \
        "the published hash.")
      mono_block(doc, @license.cert_salt.to_s)

      section(doc, "3 · Commitment formula (algorithm #{Commitment::ALGORITHM})")
      mono_block(doc,
        "commitment = SHA-256( DOMAIN || nonce_bytes || canonical_certificate )\n" \
        "DOMAIN     = \"printwright:license-certificate:v1\" + 0x00   (34 bytes)\n" \
        "nonce_bytes = hex-decode of the blinding nonce above (32 bytes)\n" \
        "canonical_certificate = the exact UTF-8 bytes of section 1")
      body(doc, "Expected result — the only value published on Hedera:")
      mono_block(doc, @bundle["commitment"].to_s, chain: true)

      section(doc, "4 · Model hash")
      body(doc, "SHA-256 of the primary printable file's exact bytes — the first model file in the " \
        "delivered ZIP. Recompute with `sha256sum` on that file; it must equal the model_hash " \
        "inside the canonical certificate:")
      mono_block(doc, @cert["model_hash"].to_s)

      section(doc, "5 · Terms hash")
      body(doc, "SHA-256 of the exact governing license text, reproduced in full starting on the " \
        "next page and served byte-identically at #{terms_text_url}:")
      mono_block(doc, @cert["terms_hash"].to_s)

      section(doc, "6 · Public evidence")
      if @sandbox
        body(doc, "Sandbox rehearsal — nothing was published to Hedera and no funds moved. The " \
          "commitment above is computable but anchored only in the local sandbox simulation.")
      else
        evidence_lines(doc)
      end
    end

    def evidence_lines(doc)
      lines = []
      lines << "payment tx:   #{@cert['payment_tx']}"
      if (tx_url = Hedera::Network.transaction_url(@cert["payment_tx"]))
        lines << "hashscan:     #{tx_url}"
      end
      if @license.anchored?
        lines << "hcs topic:    #{@license.hcs_topic_id}   sequence: #{@license.hcs_sequence_number}"
        lines << "mirror node:  #{@bundle.dig('hedera', 'mirror_url')}"
        lines << "hashscan:     https://hashscan.io/#{Hedera::Network.name}/topic/#{@license.hcs_topic_id}"
      else
        lines << "hcs anchor:   minting — the commitment publishes shortly after purchase"
      end
      lines << "live check:   #{@verify_url}"
      mono_block(doc, lines.join("\n"))
      body(doc, "The mirror node message carries the commitment base64-encoded in its `message` " \
        "field. Decode it, compare to section 3, and the Hedera consensus timestamp on that " \
        "message is independent proof of when this certificate existed.")
    end

    def license_text_pages(doc)
      doc.start_new_page
      appendix_heading(doc, "GOVERNING LICENSE TEXT — #{terms_kind_label} · #{terms_version}")
      body(doc, "The exact text whose SHA-256 is the terms hash anchored in the certificate. " \
        "Byte-identical copy served at #{terms_text_url}.")
      doc.move_down 6
      color(doc, INK)
      doc.font("Courier", size: 8) { doc.text drawable(terms_text), leading: 1.5 }
    end

    def appendix_heading(doc, text)
      color(doc, MUTED)
      doc.font("Helvetica", style: :bold, size: 8) { doc.text text, character_spacing: 1.6 }
      doc.move_down 10
    end

    def section(doc, title)
      doc.move_down 10
      color(doc, INK)
      doc.font("Helvetica", style: :bold, size: 10) { doc.text title }
      doc.move_down 4
    end

    def body(doc, text)
      color(doc, MUTED)
      doc.font("Helvetica", size: 8.5) { doc.text text, leading: 2 }
      doc.move_down 4
    end

    def mono_block(doc, text, chain: false)
      color(doc, chain ? CHAIN : INK)
      doc.font("Courier", size: 8) { doc.text drawable(text), leading: 1.5 }
      doc.move_down 4
    end

    def terms
      @bundle["terms"] || {}
    end

    def terms_text = terms["text"].to_s
    def terms_version = terms["version"].to_s
    def terms_kind_label = (terms["kind"] == "personal" ? "PERSONAL" : "COMMERCIAL PER-UNIT")

    def terms_text_url
      "#{@verify_url[%r{\Ahttps?://[^/]+}]}/license/#{terms_version}/#{terms['kind']}.txt"
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

    # Personal grants deliberately carry no sale or unit number — a sequential
    # serial would reveal the designer's cumulative personal sales to anyone
    # the buyer shows this certificate to. Commercial per-unit grants keep
    # their serial: "unit N" is part of what that license means.
    def statement_text
      title = drawable(@model.title)
      designer = drawable(@model.designer.display_name)
      if @sandbox
        "This locally simulates a #{@offer.kind == 'personal' ? 'personal' : 'commercial per-unit'} " \
          "license for #{title} by #{designer}. It grants no rights and certifies no payment or license."
      elsif @offer.kind == "personal"
        "This certifies a personal license for #{title}, granted by #{designer}. " \
          "It permits unlimited physical prints for personal, non-commercial use."
      else
        "This certifies commercial unit ##{@cert['unit_serial'] || @license.serial} of #{title}, " \
          "granted by #{designer}. It permits one physical print for commercial sale."
      end
    end

    def permissions_line
      if @offer.kind == "personal"
        "personal — unlimited personal, non-commercial prints"
      else
        serial = @cert["unit_serial"] || @license.serial
        cap = @offer.max_units ? " of #{@offer.max_units}" : ""
        "commercial unit ##{serial}#{cap} — one commercial print"
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
