require "test_helper"
require "active_storage/service/s3_service"
require "socket"
require "tmpdir"

class SaasStorageTlsTest < ActiveSupport::TestCase
  test "production beta and staging use separate buckets and their supplied credentials" do
    %w[ production beta staging ].each do |environment|
      config = storage_config(environment: environment)
      service = ActiveStorage::Service.configure(:purestorage, { purestorage: config })

      assert_equal "fizzy-#{environment}-activestorage", service.bucket.name
      assert_equal "https://storage.basecamp.com", config.fetch("endpoint")
      assert_equal "test-#{environment}-access", service.client.client.config.credentials.access_key_id
      assert_equal "test-#{environment}-secret", service.client.client.config.credentials.secret_access_key
    end
  end

  test "untrusted storage certificate fails before any signed HTTP request" do
    with_tls_storage(trusted: false) do |service, requests|
      error = assert_raises(Seahorse::Client::NetworkingError) do
        service.upload("probe", StringIO.new("attachment"))
      end

      assert_match(/certificate verify failed/, error.message)
      assert requests.empty?, "An untrusted server received an HTTP request"
    end
  end

  test "trusted certificate for another hostname fails before any signed HTTP request" do
    with_tls_storage(trusted: true, hostname: "other.example.invalid") do |service, requests|
      error = assert_raises(Seahorse::Client::NetworkingError) do
        service.upload("probe", StringIO.new("attachment"))
      end

      assert_match(/certificate verify failed|does not match the server certificate/, error.message)
      assert requests.empty?, "A server with the wrong hostname received an HTTP request"
    end
  end

  test "configured internal CA permits signed upload and download" do
    with_tls_storage(trusted: true, connections: 2) do |service, requests|
      service.upload("probe", StringIO.new("attachment"))

      assert_equal "attachment", service.download("probe")
      upload = requests.pop(timeout: 1)
      download = requests.pop(timeout: 1)
      assert_equal "PUT /fizzy-production-activestorage/probe HTTP/1.1\r\n", upload.fetch(:line)
      assert_equal "attachment", upload.fetch(:body)
      assert_match(/Credential=test-production-access\//, upload.fetch(:headers))
      assert_equal "GET /fizzy-production-activestorage/probe HTTP/1.1\r\n", download.fetch(:line)
    end
  end

  private
    def storage_config(environment: "production", ca_bundle: nil)
      original_environment = Rails.env
      values = {
        "ACTIVE_STORAGE_ACCESS_KEY_ID" => "test-#{environment}-access",
        "ACTIVE_STORAGE_SECRET_ACCESS_KEY" => "test-#{environment}-secret",
        "ACTIVE_STORAGE_SSL_CA_BUNDLE" => ca_bundle
      }
      original_values = ENV.to_h.slice(*values.keys)
      Rails.env = environment
      ENV.update(values)
      YAML.safe_load(ERB.new(Rails.root.join("saas/config/storage.yml").read).result).fetch("purestorage")
    ensure
      Rails.env = original_environment
      values.each_key { |key| ENV[key] = original_values[key] }
    end

    def with_tls_storage(trusted:, hostname: "127.0.0.1", connections: 1)
      ca_key = OpenSSL::PKey::RSA.new(2048)
      ca = certificate(ca_key, hostname: "Storage test CA", authority: true)
      key = OpenSSL::PKey::RSA.new(2048)
      leaf = certificate(key, hostname: hostname, issuer: ca, issuer_key: ca_key)
      context = OpenSSL::SSL::SSLContext.new
      context.cert = leaf
      context.key = key
      listener = TCPServer.new("127.0.0.1", 0)
      requests = Queue.new
      socket = nil
      worker = Thread.new do
        contents = ""
        connections.times do
          socket = OpenSSL::SSL::SSLSocket.new(listener.accept, context)
          socket.sync_close = true
          socket.accept
          line = socket.gets
          break unless line
          headers = +""
          length = 0
          while (header = socket.gets) && header != "\r\n"
            headers << header
            length = header.split(":", 2).last.to_i if header.downcase.start_with?("content-length:")
          end
          socket.write("HTTP/1.1 100 Continue\r\n\r\n") if headers.match?(/^expect: 100-continue\r$/i)
          body = length.positive? ? socket.read(length) : ""
          requests << { line: line, headers: headers, body: body }
          contents = body if line.start_with?("PUT ")
          response = line.start_with?("GET ") ? contents : ""
          socket.write("HTTP/1.1 200 OK\r\nContent-Length: #{response.bytesize}\r\nConnection: close\r\n\r\n#{response}")
          socket.close
        end
      rescue OpenSSL::SSL::SSLError
        # A client rejection also terminates the server handshake.
      ensure
        socket&.close
      end
      worker.report_on_exception = false

      Dir.mktmpdir("storage-ca-") do |directory|
        bundle = File.join(directory, "internal ca.pem")
        File.write(bundle, ca.to_pem)
        config = storage_config(ca_bundle: trusted ? bundle : nil).merge(
          "endpoint" => "https://127.0.0.1:#{listener.addr[1]}",
          "retry_limit" => 0, "http_open_timeout" => 2, "http_read_timeout" => 2, "http_proxy" => nil)
        service = ActiveStorage::Service.configure(:purestorage, { purestorage: config })
        WebMock.disable!
        yield service, requests
        assert worker.join(5), "TLS server did not finish"
        worker.value
      end
    ensure
      WebMock.enable!
      worker&.kill
      worker&.join(1)
      listener&.close
      socket&.close
    end

    def certificate(key, hostname:, authority: false, issuer: nil, issuer_key: key)
      certificate = OpenSSL::X509::Certificate.new
      certificate.version = 2
      certificate.serial = authority ? 1 : 2
      certificate.subject = OpenSSL::X509::Name.parse("/CN=#{hostname}")
      certificate.issuer = issuer ? issuer.subject : certificate.subject
      certificate.public_key = key.public_key
      certificate.not_before = 1.hour.ago
      certificate.not_after = 1.hour.from_now
      extensions = OpenSSL::X509::ExtensionFactory.new
      extensions.subject_certificate = certificate
      extensions.issuer_certificate = issuer || certificate
      certificate.add_extension extensions.create_extension("basicConstraints", authority ? "CA:TRUE" : "CA:FALSE", true)
      certificate.add_extension extensions.create_extension("keyUsage", authority ? "keyCertSign,cRLSign" : "digitalSignature,keyEncipherment", true)
      unless authority
        certificate.add_extension extensions.create_extension("subjectAltName", hostname == "127.0.0.1" ? "IP:#{hostname}" : "DNS:#{hostname}")
      end
      certificate.sign(issuer_key, OpenSSL::Digest.new("SHA256"))
      certificate
    end
end
