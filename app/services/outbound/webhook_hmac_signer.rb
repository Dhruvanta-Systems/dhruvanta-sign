# frozen_string_literal: true

require 'openssl'

module Outbound
  # HMAC-SHA256 signer for outbound webhook payloads.
  #
  # Wire shape: algorithm HMAC-SHA256, output lowercase hex with no `sha256=`
  # prefix, key taken from WEBHOOK_OUTBOX_SECRET (shared with the receiver).
  #
  # Stateless and side-effect free.
  class WebhookHmacSigner
    HMAC_ALGO = 'SHA256'

    # Compute the HMAC-SHA256 hex of `raw_payload` under `secret`.
    # Returns lowercase hex, no prefix. A blank or nil secret returns
    # an empty string — callers MUST treat that as a config error and
    # refuse to dispatch (avoids sending a corrupt header).
    def sign(raw_payload, secret)
      return '' if secret.nil? || secret.to_s.empty?

      body = raw_payload.to_s
      OpenSSL::HMAC.hexdigest(HMAC_ALGO, secret.to_s, body)
    rescue StandardError
      # OpenSSL::HMAC.hexdigest is reliable; this branch is defensive
      # — return empty so the dispatcher can refuse to send.
      ''
    end

    # Constant-time comparison of an emitter-computed signature against
    # an externally-provided one. Mirrors the receiver's verifier so a
    # sign → verify pair stays symmetric in tests.
    def verify(raw_payload, secret, candidate_hex)
      expected = sign(raw_payload, secret)
      return false if expected.empty? || candidate_hex.nil?

      OpenSSL.fixed_length_secure_compare(expected, candidate_hex.to_s.downcase)
    rescue ArgumentError
      false
    end
  end
end
