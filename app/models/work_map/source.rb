# Handy #2348: one aggregated, bounded read of Dédalo's execution graph for all
# products, done when someone opens the work map and kept 30 s for everybody.
# There is no copy in Fizzy's database and no read per card. A failure is
# returned as a status, never raised and never shown as an empty product.
# Contract: docs/work-map.md.
class WorkMap::Source
  Result = Data.define(:status, :error, :snapshot) do
    def ok? = status == "ok"
  end

  class Failure < StandardError; end

  TIMEOUT = 5.seconds
  MAX_BYTES = 2.megabytes
  CACHE_KEY = "work_map/source/v1"
  CACHE_TTL = 30.seconds
  FAILURE_TTL = 10.seconds

  def self.default
    new(url: ENV["WORK_MAP_SOURCE_URL"].presence, token_file: ENV["WORK_MAP_SOURCE_TOKEN_FILE"].presence,
      file: (ENV["WORK_MAP_SOURCE_FILE"].presence if Rails.env.local?))
  end

  # `file` reads a sample graph from disk instead of Dédalo, only outside
  # production: it is how the map is shown and rehearsed with sample data.
  def initialize(url: nil, token_file: nil, file: nil, cache: Rails.cache)
    @url = url
    @token_file = token_file
    @file = file
    @cache = cache
  end

  def read
    if configured?
      cached_read
    else
      Result.new(status: "not_configured", error: nil, snapshot: nil)
    end
  end

  private
    def configured?
      @file.present? || (@url.present? && @token_file.present?)
    end

    def cached_read
      if result = @cache.read(CACHE_KEY)
        result
      else
        fetch.tap { |result| @cache.write(CACHE_KEY, result, expires_in: result.ok? ? CACHE_TTL : FAILURE_TTL) }
      end
    end

    def fetch
      Result.new(status: "ok", error: nil, snapshot: WorkMap::Snapshot.parse(JSON.parse(body)))
    rescue WorkMap::Snapshot::Invalid
      failure "invalid_response"
    rescue JSON::ParserError, Encoding::UndefinedConversionError
      failure "invalid_json"
    rescue Failure => error
      failure error.message
    rescue URI::InvalidURIError
      failure "invalid_url"
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
      failure "timeout"
    rescue SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError, Zlib::Error
      failure "unreachable"
    end

    def failure(code)
      Result.new(status: "failed", error: code, snapshot: nil)
    end

    def body
      data = @file.present? ? File.read(@file, MAX_BYTES + 1) : http_body
      too_large! if data.bytesize > MAX_BYTES
      data.force_encoding(Encoding::UTF_8).tap { |text| raise Failure, "invalid_json" unless text.valid_encoding? }
    end

    def http_body
      uri = URI.parse(@url)
      raise Failure, "invalid_url" unless uri.is_a?(URI::HTTP) && uri.host.present?

      request = Net::HTTP::Get.new(uri.request_uri, "Accept" => "application/json", "Authorization" => "Bearer #{token}")

      # Net::HTTP's timeouts apply per phase and per read, and it retries an
      # idempotent GET once: only the outer timeout bounds the whole read
      # (connection, TLS, request, headers and body) to TIMEOUT (Handy #2372).
      Timeout.timeout(TIMEOUT) do
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
          open_timeout: TIMEOUT, read_timeout: TIMEOUT, write_timeout: TIMEOUT) do |http|
          read_response(http, request)
        end
      end
    end

    def read_response(http, request)
      buffer = +""
      http.request(request) do |response|
        raise Failure, "http_#{response.code.to_i}" unless response.is_a?(Net::HTTPOK)

        response.read_body do |chunk|
          buffer << chunk
          too_large! if buffer.bytesize > MAX_BYTES
        end
      end
      buffer
    end

    def token
      File.read(@token_file).strip.presence || raise(Failure, "missing_token")
    rescue SystemCallError
      raise Failure, "missing_token"
    end

    def too_large!
      raise Failure, "too_large"
    end
end
