require "test_helper"

class My::PasskeysControllerTest < ActionDispatch::IntegrationTest
  include WebauthnTestHelper

  setup do
    sign_in_as :kevin
  end

  test "index" do
    get my_passkeys_path
    assert_response :success
  end

  test "register a passkey" do
    challenge = request_webauthn_challenge(purpose: "registration")

    assert_difference -> { identities(:kevin).passkeys.count }, 1 do
      post my_passkeys_path, params: build_attestation_params(challenge: challenge)
    end

    passkey = identities(:kevin).passkeys.order(created_at: :desc).first
    assert_redirected_to edit_my_passkey_path(passkey, created: true)
    assert_equal [ "internal" ], passkey.transports
  end

  test "filters WebAuthn attestation fields from logged parameters" do
    challenge = request_webauthn_challenge(purpose: "registration")

    post my_passkeys_path, params: build_attestation_params(challenge: challenge)

    %w[ client_data_json attestation_object ].each do |field|
      assert_equal "[FILTERED]", request.filtered_parameters.dig("passkey", field), "#{field} reached the log"
    end
  end

  test "malformed attestation is rejected with a redirect, not a 500" do
    challenge = request_webauthn_challenge(purpose: "registration")
    params = build_attestation_params(challenge: challenge)
    params[:passkey][:attestation_object] = "this-is-not-a-valid-attestation-object"

    assert_no_difference -> { identities(:kevin).passkeys.count } do
      post my_passkeys_path, params: params
    end

    assert_redirected_to my_passkeys_path
    assert_equal "We couldn't register that passkey. Please try again.", flash[:alert]
  end

  test "re-registering an existing credential is rejected with a friendly message" do
    challenge = request_webauthn_challenge(purpose: "registration")
    credential_id = SecureRandom.random_bytes(32)

    post my_passkeys_path, params: build_attestation_params(challenge: challenge, credential_id: credential_id)
    assert_response :redirect

    challenge = request_webauthn_challenge(purpose: "registration")
    assert_no_difference -> { ActionPack::Passkey.count } do
      post my_passkeys_path, params: build_attestation_params(challenge: challenge, credential_id: credential_id)
    end

    assert_redirected_to my_passkeys_path
    assert_equal "That passkey is already registered.", flash[:alert]
  end

  # One registration per test: a route helper in an assertion changes the
  # session's script name, and the next untenanted challenge request redirects.
  [ 2048, 4096 ].each do |bits|
    test "register an RS256 passkey with a #{bits}-bit modulus" do
      rsa_key = OpenSSL::PKey::RSA.generate(bits)
      challenge = request_webauthn_challenge(purpose: "registration")
      cose_public_key = cose_rsa_public_key(modulus: rsa_key.n.to_s(2), exponent: rsa_key.e.to_s(2))

      assert_difference -> { identities(:kevin).passkeys.count }, 1 do
        post my_passkeys_path, params: build_attestation_params(challenge: challenge, cose_public_key: cose_public_key)
      end

      passkey = identities(:kevin).passkeys.order(created_at: :desc).first
      assert_redirected_to edit_my_passkey_path(passkey, created: true)
      assert_equal rsa_key.public_to_der, passkey.to_public_key_credential.public_key.public_to_der
    end
  end

  {
    "a 4097-bit modulus" => { modulus: "\x01".b + SecureRandom.random_bytes(512) },
    "a 64 KiB modulus" => { modulus: "\xff".b * 64.kilobytes },
    "a huge odd exponent" => { exponent: "\x01".b + ("\xff".b * 8.kilobytes) },
    "an even exponent" => { exponent: [ 65536 ].pack("N") },
    "the exponent 3" => { exponent: "\x03".b },
    "the exponent 2^32 + 1" => { exponent: "\x01\x00\x00\x00\x01".b }
  }.each do |label, key_parts|
    test "an RS256 passkey with #{label} is not registered" do
      modulus = key_parts.fetch(:modulus) { OpenSSL::PKey::RSA.generate(2048).n.to_s(2) }
      exponent = key_parts.fetch(:exponent, "\x01\x00\x01".b)
      challenge = request_webauthn_challenge(purpose: "registration")
      assert challenge.present?, "the registration challenge was not issued"

      assert_no_difference -> { ActionPack::Passkey.count } do
        post my_passkeys_path, params: build_attestation_params(challenge: challenge, cose_public_key: cose_rsa_public_key(modulus: modulus, exponent: exponent))
      end

      assert_redirected_to my_passkeys_path
      assert_equal "We couldn't register that passkey. Please try again.", flash[:alert]
    end
  end
end
