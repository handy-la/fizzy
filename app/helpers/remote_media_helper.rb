module RemoteMediaHelper
  def remote_media_link(attachment, label:)
    uri = URI.parse(attachment.url.to_s)

    if uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.nil?
      link_to "#{label}: abrir en el sitio externo (comparte tu conexión)", uri.to_s,
        target: "_blank", rel: "noopener noreferrer"
    else
      tag.span "#{label}: enlace externo no disponible."
    end
  rescue URI::InvalidURIError
    tag.span "#{label}: enlace externo no disponible."
  end
end
