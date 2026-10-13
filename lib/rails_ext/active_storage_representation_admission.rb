# Handy #968: the representation controllers run the parser synchronously on a GET, against a
# processor shared by every account. Three limits stand in front of it, and only in front of work
# that is still to do — an already processed representation costs nothing and is never refused:
#
# * A permanent failure is remembered. Its verdict is keyed by the blob (id and checksum), its
#   content type, the variation and the processor version, so any of them changing earns a new
#   attempt, and it expires after VERDICT_TTL. Only the classes in +permanent_errors+ are recorded
#   (the SaaS registers the cell's UnprocessableAttachment); a transient failure never is. The blob
#   id is part of the key because MD5 checksums can be made to collide: a verdict on one account's
#   file must not answer for another's.
# * One identity may start PROCESSINGS_PER_MINUTE processings a minute (the client IP when there
#   is no identity, as on a public board).
# * One account may hold CONCURRENCY_PER_ACCOUNT processings at once, so it cannot take every
#   worker of the cell. A refused request answers 429 at once rather than queueing in the cell.
#
# Everything lives in Rails.cache, which is Solid Cache and therefore shared by every process in
# production. A slot left behind by a dead process expires after SLOT_TTL, longer than the cell's
# own timeout.
module ActiveStorage::RepresentationAdmission
  CONCURRENCY_PER_ACCOUNT = 2
  PROCESSINGS_PER_MINUTE = 30
  VERDICT_TTL = 1.day
  SLOT_TTL = 3.minutes

  PROCESSOR_GEMS = %w[ activestorage activestorage-hotcell-client hotcell-client image_processing ruby-vips ]

  mattr_accessor :permanent_errors, default: []

  class << self
    def verdict_recorded?(blob, variation)
      Rails.cache.exist?(verdict_key(blob, variation))
    end

    def record_verdict(blob, variation)
      Rails.cache.write(verdict_key(blob, variation), true, expires_in: VERDICT_TTL)
    end

    def permanent?(error)
      permanent_errors.any? { |klass| error.is_a?(klass) }
    end

    # A fixed one-minute window, as Rails' own rate_limit counts.
    def within_rate?(principal)
      window = Time.current.to_i / 1.minute
      count = Rails.cache.increment([ "active_storage/representation_rate", principal, window ].join("/"), 1, expires_in: 2.minutes)

      count.nil? || count <= PROCESSINGS_PER_MINUTE
    end

    def acquire_slot(account_id)
      token = SecureRandom.uuid

      CONCURRENCY_PER_ACCOUNT.times do |index|
        key = "active_storage/representation_slot/#{account_id}/#{index}"

        if Rails.cache.write(key, token, unless_exist: true, expires_in: SLOT_TTL)
          return [ key, token ]
        end
      end

      nil
    end

    def release_slot((key, token))
      Rails.cache.delete(key) if Rails.cache.read(key) == token
    end

    def processor_version
      @processor_version ||= begin
        gems = PROCESSOR_GEMS.map { |name| "#{name}-#{Gem.loaded_specs[name]&.version}" }
        components = [ ActiveStorage.variant_processor, *ActiveStorage.previewers, *ActiveStorage.analyzers ].map(&:to_s)

        OpenSSL::Digest::SHA256.hexdigest((gems + components).join("\n"))
      end
    end

    private
      def verdict_key(blob, variation)
        [ "active_storage/representation_verdict", blob.id, blob.checksum, blob.content_type, variation.digest, processor_version ].join("/")
      end
  end

  module Controller
    private
      def set_representation
        representation = @blob.representation(params[:variation_key])

        if representation_processed?(representation)
          @representation = representation.processed
        else
          admit_processing(representation)
        end
      rescue ActiveSupport::MessageVerifier::InvalidSignature
        head :not_found
      end

      def representation_processed?(representation)
        if representation.is_a?(ActiveStorage::Preview)
          representation.processed? && representation_variant_processed?(representation)
        else
          representation.processed?
        end
      end

      def representation_variant_processed?(preview)
        preview.variation.transformations.blank? || preview.image.variant(preview.variation).processed?
      end

      def admit_processing(representation)
        admission = ActiveStorage::RepresentationAdmission

        if admission.verdict_recorded?(@blob, representation.variation)
          head :unprocessable_entity
        elsif !admission.within_rate?(representation_principal)
          refuse_representation
        elsif slot = admission.acquire_slot(@blob.account_id)
          begin
            @representation = representation.processed
          rescue => error
            admission.record_verdict(@blob, representation.variation) if admission.permanent?(error)
            raise
          ensure
            admission.release_slot(slot)
          end
        else
          refuse_representation
        end
      end

      def representation_principal
        if Current.identity
          "identity/#{Current.identity.id}"
        else
          "ip/#{request.remote_ip}"
        end
      end

      def refuse_representation
        response.headers["Retry-After"] = "5"
        head :too_many_requests
      end
  end
end

Rails.application.config.to_prepare do
  ActiveStorage::Representations::BaseController.prepend ActiveStorage::RepresentationAdmission::Controller
end
