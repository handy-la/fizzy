module WebauthnTestHelper
  # Fixed EC P-256 key pair for WebAuthn tests.
  WEBAUTHN_PRIVATE_KEY = OpenSSL::PKey::EC.new(
    [ "307702010104201dd589de7210b3318620f32150e3012cce021519df1d6e9e01" \
      "0471146d395cdca00a06082a8648ce3d030107a14403420004116847fe19e1ad" \
      "4471ab9980d7ff9cc1e4c7cb7a3af00e082b64fcd84f5ae70114c2495eef16f" \
      "542b5e57dd1b263661624e3cf28f581b57a441edbd756a41d0e" ].pack("H*")
  )

  # Pre-encoded COSE EC2/ES256 public key (CBOR) for the key above.
  # {1: 2, 3: -7, -1: 1, -2: <x 32 bytes>, -3: <y 32 bytes>}
  COSE_PUBLIC_KEY = [ "a5010203262001215820116847fe19e1ad4471ab9980d7ff9cc1" \
    "e4c7cb7a3af00e082b64fcd84f5ae70122582014c2495eef16f542b5e57dd1b2" \
    "63661624e3cf28f581b57a441edbd756a41d0e" ].pack("H*")

  # CBOR prefix for {"fmt": "none", "attStmt": {}, "authData": bytes(164)}.
  # Auth data is always 164 bytes: rp_id_hash(32) + flags(1) + sign_count(4)
  # + aaguid(16) + credential_id_length(2) + credential_id(32) + cose_key(77).
  ATTESTATION_OBJECT_CBOR_PREFIX =
    [ "a363666d74646e6f6e656761747453746d74a068617574684461746158a4" ].pack("H*")

  # The same map without the authData length: a cbor_byte_string header follows,
  # sized for auth data that carries another COSE key.
  ATTESTATION_OBJECT_MAP_PREFIX =
    [ "a363666d74646e6f6e656761747453746d74a0686175746844617461" ].pack("H*")

  private
    def request_webauthn_challenge(purpose: "authentication")
      untenanted { post my_passkey_challenge_url, params: { purpose: purpose } }
      response.parsed_body["challenge"]
    end

    def webauthn_challenge(purpose: nil)
      ActionPack::WebAuthn::PublicKeyCredential::Options.new(challenge_purpose: purpose).challenge
    end

    def webauthn_private_key
      WEBAUTHN_PRIVATE_KEY
    end

    def build_attestation_params(challenge:, credential_id: SecureRandom.random_bytes(32), cose_public_key: COSE_PUBLIC_KEY)
      auth_data = build_attestation_auth_data(credential_id: credential_id, cose_public_key: cose_public_key)

      {
        passkey: {
          client_data_json: webauthn_client_data_json(challenge: challenge, type: "webauthn.create"),
          attestation_object: Base64.urlsafe_encode64(ATTESTATION_OBJECT_MAP_PREFIX + cbor_byte_string(auth_data), padding: false),
          transports: [ "internal" ]
        }
      }
    end

    def build_assertion_params(challenge:, credential:, sign_count: 1)
      client_data_json = webauthn_client_data_json(challenge: challenge, type: "webauthn.get")
      authenticator_data = build_assertion_auth_data(sign_count: sign_count)
      signature = webauthn_sign(authenticator_data, client_data_json)

      {
        passkey: {
          id: credential.credential_id,
          client_data_json: client_data_json,
          authenticator_data: Base64.urlsafe_encode64(authenticator_data, padding: false),
          signature: Base64.urlsafe_encode64(signature, padding: false)
        }
      }
    end

    def webauthn_client_data_json(challenge:, type:)
      { challenge: challenge, origin: "http://www.example.com", type: type }.to_json
    end

    # Attestation auth data includes the attested credential (public key + credential ID).
    def build_attestation_auth_data(credential_id:, cose_public_key: COSE_PUBLIC_KEY)
      [
        Digest::SHA256.digest("www.example.com"),   # rp_id_hash
        [ 0x45 ].pack("C"),                         # flags: UP + UV + AT
        [ 0 ].pack("N"),                            # sign_count
        "\x00" * 16,                                # aaguid
        [ credential_id.bytesize ].pack("n"),       # credential_id_length
        credential_id,
        cose_public_key
      ].join.b
    end

    # COSE RSA/RS256 public key (CBOR): {1: 3, 3: -257, -1: <n>, -2: <e>}.
    def cose_rsa_public_key(modulus:, exponent:)
      [ "a401030339010020" ].pack("H*") + cbor_byte_string(modulus) +
        [ 0x21 ].pack("C") + cbor_byte_string(exponent)
    end

    def cbor_byte_string(bytes)
      header =
        case bytes.bytesize
        when 0..23 then [ 0x40 + bytes.bytesize ].pack("C")
        when 24..0xff then [ 0x58, bytes.bytesize ].pack("CC")
        when 0x100..0xffff then [ 0x59, bytes.bytesize ].pack("Cn")
        else [ 0x5a, bytes.bytesize ].pack("CN")
        end

      header.b + bytes.b
    end

    # Assertion auth data is simpler — no attested credential.
    def build_assertion_auth_data(sign_count:)
      [
        Digest::SHA256.digest("www.example.com"),
        [ 0x05 ].pack("C"),                         # flags: UP + UV
        [ sign_count ].pack("N")
      ].join.b
    end

    def webauthn_sign(authenticator_data, client_data_json)
      signed_data = authenticator_data + Digest::SHA256.digest(client_data_json)
      WEBAUTHN_PRIVATE_KEY.sign("SHA256", signed_data)
    end
end
