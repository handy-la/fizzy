module QrCodesHelper
  # The QR code is embedded in the page as a data URI. A URL that served it would carry the encoded
  # link (an auto-login or invite capability) into every request log.
  def qr_code_image(url)
    svg = RQRCode::QRCode.new(url).as_svg(viewbox: true, fill: :white, color: :black, offset: 16)
    image_tag "data:image/svg+xml;base64,#{Base64.strict_encode64(svg)}", class: "qr-code center", alt: "QR Code"
  end
end
