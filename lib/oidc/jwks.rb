# frozen_string_literal: true

require 'faraday'

module Oidc
  # The provider's signing keys, from the jwks_uri in its discovery document (a
  # `jku` or `x5u` in a token header is never followed). The set is cached for five
  # minutes; an unknown `kid` forces one refetch (a key rotation), at most
  # MAX_FORCED_REFETCHES_PER_MINUTE times a minute so a flood of made-up kids does
  # not become a flood of requests to the provider.
  module Jwks
    TTL = 5.minutes
    TIMEOUT = 5
    MAX_FORCED_REFETCHES_PER_MINUTE = 5

    @mutex = Mutex.new
    @cached = nil

    module_function

    # @return [JSON::JWK, nil]
    def key_for(kid)
      keys = current_keys
      found = find(keys, kid)
      return found if found || !refetch_allowed?

      find(fetch!, kid)
    end

    def reset!
      @mutex.synchronize { @cached = nil }
    end

    def current_keys
      uri = Provider.config.jwks_uri

      @mutex.synchronize { return @cached[:keys] if @cached && @cached[:uri] == uri && Time.current - @cached[:at] < TTL }

      fetch!
    end

    def fetch!
      uri = Provider.config.jwks_uri
      response = Faraday.get(uri) do |req|
        req.options.timeout = TIMEOUT
        req.options.open_timeout = TIMEOUT
      end
      raise Error.new('jwks_unavailable', :service_unavailable) unless response.success?

      keys = JSON::JWK::Set.new(JSON.parse(response.body)['keys'] || [])
      @mutex.synchronize { @cached = { uri:, keys:, at: Time.current } }
      keys
    rescue Error
      raise
    rescue StandardError => e
      Rails.logger.warn("Oidc jwks fetch failed: #{e.class}")
      raise Error.new('jwks_unavailable', :service_unavailable, 'The sign-in service is unavailable.')
    end

    def find(keys, kid)
      return keys.first if kid.blank? && keys.size == 1

      keys.detect { |key| key[:kid] == kid } if kid.present?
    end

    def refetch_allowed?
      RateLimit.call('oidc-jwks-refetch', limit: MAX_FORCED_REFETCHES_PER_MINUTE, ttl: 1.minute, enabled: true)
    rescue RateLimit::LimitApproached
      false
    end
  end
end
