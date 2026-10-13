require "test_helper"
require "socket"

class Webhook::TlsTest < ActiveSupport::TestCase
  setup do
    webhook_deliveries(:in_progress).completed!
  end

  test "pinned connection uses the logical hostname for SNI and certificate verification" do
    with_tls_endpoint(certificate_hostname: "webhook.example.invalid", trusted: true) do |delivery, observed|
      delivery.deliver

      assert delivery.succeeded?
      assert_equal "webhook.example.invalid", observed.pop(timeout: 1)
    end
  end

  test "rejects a trusted certificate for another hostname" do
    with_tls_endpoint(certificate_hostname: "attacker.example.invalid", trusted: true) do |delivery, observed|
      delivery.deliver

      assert_equal "failed_tls", delivery.response[:error]
      assert_not delivery.succeeded?
      assert_equal "webhook.example.invalid", observed.pop(timeout: 1)
    end
  end

  test "rejects an untrusted certificate for the correct hostname" do
    with_tls_endpoint(certificate_hostname: "webhook.example.invalid", trusted: false) do |delivery, observed|
      delivery.deliver

      assert_equal "failed_tls", delivery.response[:error]
      assert_not delivery.succeeded?
      assert_equal "webhook.example.invalid", observed.pop(timeout: 1)
    end
  end

  private
    def with_tls_endpoint(certificate_hostname:, trusted:)
      key = OpenSSL::PKey::RSA.new(2048)
      certificate = OpenSSL::X509::Certificate.new
      certificate.version = 2
      certificate.serial = 1
      certificate.subject = certificate.issuer = OpenSSL::X509::Name.parse("/CN=#{certificate_hostname}")
      certificate.public_key = key.public_key
      certificate.not_before = 1.hour.ago
      certificate.not_after = 1.hour.from_now
      extensions = OpenSSL::X509::ExtensionFactory.new
      extensions.subject_certificate = extensions.issuer_certificate = certificate
      certificate.add_extension extensions.create_extension("basicConstraints", "CA:TRUE", true)
      certificate.add_extension extensions.create_extension("subjectAltName", "DNS:#{certificate_hostname}")
      certificate.sign(key, OpenSSL::Digest.new("SHA256"))

      observed = Queue.new
      context = OpenSSL::SSL::SSLContext.new
      context.cert = certificate
      context.key = key
      context.servername_cb = proc do |_, hostname|
        observed << hostname
        nil
      end
      listener = TCPServer.new("127.0.0.1", 0)
      socket = nil
      worker = Thread.new do
        socket = OpenSSL::SSL::SSLSocket.new(listener.accept, context)
        socket.sync_close = true
        socket.accept
        length = 0
        while (line = socket.gets) && line != "\r\n"
          length = line.split(":", 2).last.to_i if line.downcase.start_with?("content-length:")
        end
        socket.read(length)
        socket.write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      rescue OpenSSL::SSL::SSLError
        # A rejected certificate also terminates the server handshake.
      ensure
        socket&.close
      end
      worker.report_on_exception = false

      port = listener.addr[1]
      WebMock.disable!
      client = Net::HTTP.new("webhook.example.invalid", port, nil)
      store = OpenSSL::X509::Store.new
      store.add_cert(certificate) if trusted
      client.cert_store = store
      Net::HTTP.expects(:new).with("webhook.example.invalid", port, nil).returns(client)
      Surfguard.stubs(:resolve_public_ips).with("webhook.example.invalid").returns([ "127.0.0.1" ])
      webhook = Webhook.create!(board: boards(:writebook), name: "TLS", url: "https://webhook.example.invalid:#{port}/hook")
      delivery = Webhook::Delivery.create!(webhook: webhook, event: events(:layout_commented))

      yield delivery, observed
      assert worker.join(5), "TLS endpoint did not finish"
    ensure
      WebMock.enable!
      listener&.close
      socket&.close
      worker&.kill
      worker&.join(1)
    end
end
