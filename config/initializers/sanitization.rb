Rails.application.config.after_initialize do
  Rails::HTML5::SafeListSanitizer.allowed_tags.merge(%w[ s table tr td th thead tbody details summary video source ])
  Rails::HTML5::SafeListSanitizer.allowed_attributes.merge(%w[ data-turbo-frame data-lightbox-target data-lightbox-caption-value controls type width ])

  # ugh, see https://github.com/rails/rails/issues/54478 which I need to fix upstream --mike
  ActionText::ContentHelper.allowed_tags = Rails::HTML5::SafeListSanitizer.allowed_tags.to_a + [ ActionText::Attachment.tag_name, "figure", "figcaption" ] + ActionText::ContentHelper.allowed_tags.to_a
  # Preserve the no-referrer links emitted for remote media after rendering.
  ActionText::ContentHelper.allowed_attributes = Rails::HTML5::SafeListSanitizer.allowed_attributes.to_a + ActionText::Attachment::ATTRIBUTES + ActionText::ContentHelper.allowed_attributes.to_a + %w[ rel target ]

  # An explicit scrubber replaces the sanitizer's tag/attribute options.
  # Keep the existing allowlists as well as normalizing authored links.
  # Lexxy 1.0.4 adds its markup in an after_initialize that runs after this
  # one, and the scrubber keeps a copy of the lists: name Lexxy's markup here
  # too, or code blocks lose data-language and audio is dropped (Handy 2433).
  lexxy_tags = %w[ s u video audio source embed table tbody tr th td ]
  lexxy_attributes = %w[ controls poster data-language style value start ]
  link_scrubber = ActionTextLinkScrubber.new
  link_scrubber.tags = ActionText::ContentHelper.allowed_tags | lexxy_tags
  link_scrubber.attributes = ActionText::ContentHelper.allowed_attributes | lexxy_attributes
  ActionText::ContentHelper.scrubber = link_scrubber
end
