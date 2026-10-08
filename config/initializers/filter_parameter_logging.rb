# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += %i[
  passw secret token _key crypt salt certificate otp ssn
]

# WebAuthn ceremony fields: a signed assertion read from a log could otherwise be replayed, and
# the credential ID links a log line to one authenticator. "passkey.id" is the credential ID
# submitted with an assertion.
Rails.application.config.filter_parameters += %i[
  client_data_json authenticator_data signature attestation_object credential_id
]
Rails.application.config.filter_parameters += [ "passkey.id" ]
