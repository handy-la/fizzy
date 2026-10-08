# = Action Pack Passkey Consumed Challenge
#
# Records each authentication challenge that already signed someone in, so the
# same assertion cannot be replayed while its challenge is still valid. The
# challenge itself stays stateless; only its use is recorded.
#
# The unique index on +digest+ is what makes consumption atomic: of two
# concurrent requests that carry the same challenge, the database accepts
# exactly one insert and the other raises.
class ActionPack::Passkey::ConsumedChallenge < Rails.configuration.action_pack.passkey.parent_class_name.constantize
  self.table_name = "action_pack_passkey_consumed_challenges"

  scope :expired, -> { where(expires_at: ...Time.current) }

  class << self
    # Records +challenge+ (the verified challenge payload) as used. Raises
    # ActionPack::WebAuthn::InvalidResponseError when it was used before or has
    # expired by now.
    #
    # The expiry is checked after the insert: +cleanup+ deletes a row only once
    # its challenge has expired, so a request that validated in time but stalled
    # until after that deletion inserts a fresh row and must still be refused.
    # Call it inside the transaction that acts on the challenge, so the refusal
    # rolls the insert back.
    def consume!(challenge, expires_at:)
      transaction do
        create!(digest: Digest::SHA256.hexdigest(challenge), expires_at: expires_at)

        if expires_at&.<=(Time.current)
          raise ActionPack::WebAuthn::InvalidResponseError, "Challenge has expired"
        end
      end
    rescue ActiveRecord::RecordNotUnique
      raise ActionPack::WebAuthn::InvalidResponseError, "Challenge was already used"
    end

    # Forgets challenges that can no longer be verified anyway. A challenge
    # issued without an expiration is kept, because it never stops verifying.
    def cleanup
      expired.delete_all
    end
  end
end
