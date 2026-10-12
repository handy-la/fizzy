require "test_helper"

class ActionPack::PasskeyTest < ActiveSupport::TestCase
  include WebauthnTestHelper

  setup do
    @identity = identities(:kevin)
    @private_key = OpenSSL::PKey::EC.generate("prime256v1")

    ActionPack::WebAuthn::Current.host = "www.example.com"
    ActionPack::WebAuthn::Current.origin = "http://www.example.com"

    @passkey = @identity.passkeys.create!(
      credential_id: Base64.urlsafe_encode64(SecureRandom.random_bytes(32), padding: false),
      public_key: @private_key.public_to_der,
      sign_count: 0,
      transports: [ "internal" ]
    )

    @web_authn_config = Rails.configuration.action_pack.web_authn
    @default_request_options = @web_authn_config.default_request_options
    @default_creation_options = @web_authn_config.default_creation_options
  end

  teardown do
    @web_authn_config.default_request_options = @default_request_options
    @web_authn_config.default_creation_options = @default_creation_options
  end

  test "authenticate with valid assertion" do
    challenge = ActionPack::Passkey.authentication_options(credentials: [ @passkey ]).challenge
    assertion = build_assertion(challenge: challenge)

    result = @passkey.authenticate(assertion)

    assert_equal @passkey, result
  end

  test "authenticate returns nil with invalid signature" do
    challenge = ActionPack::Passkey.authentication_options(credentials: [ @passkey ]).challenge
    assertion = build_assertion(challenge: challenge)
    assertion[:signature] = Base64.urlsafe_encode64("invalid", padding: false)

    assert_nil @passkey.authenticate(assertion)
  end

  test "authenticate updates sign count and backed_up" do
    challenge = ActionPack::Passkey.authentication_options(credentials: [ @passkey ]).challenge
    assertion = build_assertion(challenge: challenge, sign_count: 5, backed_up: true)

    @passkey.authenticate(assertion)

    assert_equal 5, @passkey.reload.sign_count
    assert @passkey.backed_up?
  end

  test "authenticates a replayed zero-counter assertion only once, even from two loaded copies" do
    # Two requests that race read the same passkey row before either writes.
    first, second = ActionPack::Passkey.find(@passkey.id), ActionPack::Passkey.find(@passkey.id)
    challenge = ActionPack::Passkey.authentication_options(credentials: [ @passkey ]).challenge
    assertion = build_assertion(challenge: challenge, sign_count: 0)

    assert_equal first, first.authenticate(assertion)
    assert_nil second.authenticate(assertion)
    assert_nil ActionPack::Passkey.authenticate(assertion)
  end

  test "updates the sign count only once when two assertions race on a stale counter" do
    first, second = ActionPack::Passkey.find(@passkey.id), ActionPack::Passkey.find(@passkey.id)
    first_assertion = build_assertion(challenge: ActionPack::Passkey.authentication_options.challenge, sign_count: 5)
    second_assertion = build_assertion(challenge: ActionPack::Passkey.authentication_options.challenge, sign_count: 5)

    assert_equal first, first.authenticate(first_assertion)
    assert_nil second.authenticate(second_assertion)
    assert_equal 5, @passkey.reload.sign_count
  end

  test "a failed assertion does not consume its challenge" do
    challenge = ActionPack::Passkey.authentication_options.challenge
    assertion = build_assertion(challenge: challenge)
    forged = assertion.merge(signature: Base64.urlsafe_encode64("invalid", padding: false))

    assert_nil @passkey.authenticate(forged)
    assert_equal @passkey, @passkey.authenticate(assertion)
  end

  test "rejects an expired challenge" do
    challenge = ActionPack::Passkey.authentication_options.challenge
    assertion = build_assertion(challenge: challenge)

    travel Rails.configuration.action_pack.web_authn.request_challenge_expiration + 1.second

    assert_nil @passkey.authenticate(assertion)
  end

  test "rejects a challenge issued for another purpose" do
    challenge = ActionPack::Passkey.registration_options(holder: @identity).challenge

    assert_nil @passkey.authenticate(build_assertion(challenge: challenge))
  end

  test "a request that stalls past the expiry cannot consume a challenge that cleanup forgot" do
    # A request validates the challenge, then stalls; another consumes it and cleanup later
    # deletes that row. The stalled request reaches consume! with the challenge already expired.
    expires_at = 5.minutes.from_now
    ActionPack::Passkey::ConsumedChallenge.consume!("nonce:#{expires_at.to_i}", expires_at: expires_at)

    travel 5.minutes + 1.second
    ActionPack::Passkey::ConsumedChallenge.cleanup

    assert_raises ActionPack::WebAuthn::InvalidResponseError do
      ActionPack::Passkey::ConsumedChallenge.consume!("nonce:#{expires_at.to_i}", expires_at: expires_at)
    end
  end

  test "cleanup forgets consumed challenges only once they have expired" do
    @passkey.authenticate(build_assertion(challenge: ActionPack::Passkey.authentication_options.challenge))

    ActionPack::Passkey::ConsumedChallenge.cleanup
    assert_equal 1, ActionPack::Passkey::ConsumedChallenge.count

    travel Rails.configuration.action_pack.web_authn.request_challenge_expiration + 1.second
    ActionPack::Passkey::ConsumedChallenge.cleanup
    assert_equal 0, ActionPack::Passkey::ConsumedChallenge.count
  end

  # user_verification policy (handy-945): the server enforces the policy it asked the browser
  # for, and never trusts the browser to apply it. Authorship notes:
  # docs/test-audits/handy-945.md.
  test "rejects an assertion without user verification when the configured policy requires it" do
    @web_authn_config.default_request_options = { user_verification: :required }
    challenge = preferred_challenge(purpose: "authentication")

    assert_nil ActionPack::Passkey.authenticate(build_assertion(challenge: challenge, user_verified: false))
    assert_equal @passkey, ActionPack::Passkey.authenticate(build_assertion(challenge: challenge, user_verified: true))
  end

  test "rejects an assertion without user verification when the holder's policy requires it" do
    Identity.any_instance.stubs(:passkey_authentication_options).returns({ user_verification: "required" })
    challenge = preferred_challenge(purpose: "authentication")

    assert_nil ActionPack::Passkey.authenticate(build_assertion(challenge: challenge, user_verified: false))
    assert_equal @passkey, ActionPack::Passkey.authenticate(build_assertion(challenge: challenge, user_verified: true))
  end

  test "a challenge signed with a required policy stays required after the policy is relaxed" do
    challenge = ActionPack::Passkey.authentication_options(holder: @identity, user_verification: :required).challenge

    assert_nil ActionPack::Passkey.authenticate(build_assertion(challenge: challenge, user_verified: false))
    assert_equal @passkey, ActionPack::Passkey.authenticate(build_assertion(challenge: challenge, user_verified: true))
  end

  test "a policy tightened after the challenge was issued applies at validation" do
    challenge = ActionPack::Passkey.authentication_options(holder: @identity).challenge
    Identity.any_instance.stubs(:passkey_authentication_options).returns({ user_verification: :required })

    assert_nil ActionPack::Passkey.authenticate(build_assertion(challenge: challenge, user_verified: false))
  end

  test "accepts an assertion without user verification when no policy requires it" do
    challenge = ActionPack::Passkey.authentication_options(holder: @identity).challenge

    assert_equal @passkey, ActionPack::Passkey.authenticate(build_assertion(challenge: challenge, user_verified: false))
  end

  test "rejects a registration without user verification when the configured policy requires it" do
    @web_authn_config.default_creation_options = { user_verification: :required }
    challenge = preferred_challenge(purpose: "registration")

    assert_raises ActionPack::WebAuthn::InvalidResponseError do
      @identity.passkeys.register(build_registration(challenge: challenge, user_verified: false))
    end

    assert_difference -> { @identity.passkeys.count }, 1 do
      @identity.passkeys.register(build_registration(challenge: challenge, user_verified: true))
    end
  end

  test "rejects a registration without user verification when the holder's policy requires it" do
    Identity.any_instance.stubs(:passkey_registration_options).returns({ user_verification: :required })
    challenge = preferred_challenge(purpose: "registration")

    assert_raises ActionPack::WebAuthn::InvalidResponseError do
      @identity.passkeys.register(build_registration(challenge: challenge, user_verified: false))
    end
  end

  test "persists a spec-legal uint32-max sign count" do
    # WebAuthn sign counts are unsigned 32-bit; the column must hold the full
    # range. A signed INT4 column overflowed at 2147483647 with a RangeError.
    max_uint32 = 4_294_967_295

    @passkey.update!(sign_count: max_uint32)

    assert_equal max_uint32, @passkey.reload.sign_count
  end

  test "to_public_key_credential" do
    credential = @passkey.to_public_key_credential

    assert_equal @passkey.credential_id, credential.id
    assert_equal @passkey.sign_count, credential.sign_count
    assert_equal @passkey.transports, credential.transports
  end

  private
    # A challenge as the unauthenticated challenge endpoint issued it before handy-945: it
    # carries no policy, so only the server's own policy can require verification.
    def preferred_challenge(purpose:)
      ActionPack::WebAuthn::PublicKeyCredential::Options.new(challenge_purpose: purpose, challenge_expiration: 5.minutes).challenge
    end

    def build_registration(challenge:, user_verified:)
      auth_data = build_attestation_auth_data(credential_id: SecureRandom.random_bytes(32))
      auth_data[32] = [ user_verified ? 0x45 : 0x41 ].pack("C") # UP + AT, plus UV when verified

      {
        client_data_json: webauthn_client_data_json(challenge: challenge, type: "webauthn.create"),
        attestation_object: Base64.urlsafe_encode64(ATTESTATION_OBJECT_CBOR_PREFIX + auth_data, padding: false),
        transports: [ "internal" ]
      }
    end

    def build_assertion(challenge:, sign_count: 1, backed_up: false, user_verified: true)
      origin = ActionPack::WebAuthn::Current.origin

      client_data_json = {
        challenge: challenge,
        origin: origin,
        type: "webauthn.get"
      }.to_json

      authenticator_data = build_authenticator_data(sign_count: sign_count, backed_up: backed_up, user_verified: user_verified)
      signature = sign(authenticator_data, client_data_json)

      {
        id: @passkey.credential_id,
        client_data_json: client_data_json,
        authenticator_data: Base64.urlsafe_encode64(authenticator_data, padding: false),
        signature: Base64.urlsafe_encode64(signature, padding: false)
      }
    end

    def build_authenticator_data(sign_count:, backed_up: false, user_verified: true)
      rp_id_hash = Digest::SHA256.digest(ActionPack::WebAuthn::Current.host)
      flags = 0x01 # user present
      flags |= 0x04 if user_verified
      flags |= 0x08 | 0x10 if backed_up # backup eligible + backup state

      bytes = []
      bytes.concat(rp_id_hash.bytes)
      bytes << flags
      bytes.concat([ sign_count ].pack("N").bytes)
      bytes.pack("C*")
    end

    def sign(authenticator_data, client_data_json)
      client_data_hash = Digest::SHA256.digest(client_data_json)
      signed_data = authenticator_data + client_data_hash
      @private_key.sign("SHA256", signed_data)
    end
end
