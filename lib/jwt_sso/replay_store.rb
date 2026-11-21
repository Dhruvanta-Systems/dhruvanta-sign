# frozen_string_literal: true

module JwtSso
  # Remembers which token ids (jti) have been accepted so a token cannot be used
  # twice. In hosted mode the memory is the Redis that Sidekiq uses, so it is
  # shared by every app process; otherwise the Rails cache is used (stock).
  module ReplayStore
    class Unavailable < StandardError; end

    STORE_ERRORS = RateLimit::Shared::STORE_ERRORS

    module_function

    # @return [Boolean] true the first time a jti is seen within `ttl`, false after
    # @raise [Unavailable] hosted mode and the shared store cannot be reached
    def claim?(jti, ttl:, cache: Rails.cache)
      return claim_in_cache?(jti, ttl, cache) unless Extensions.hosted?

      Sidekiq.redis { |conn| conn.call('SET', "dsign:jti:#{jti}", '1', 'NX', 'EX', ttl.to_i) } == 'OK'
    rescue *STORE_ERRORS => e
      raise Unavailable, e.class.name
    end

    def claim_in_cache?(jti, ttl, cache)
      key = "sso_handoff_jti:#{jti}"
      claimed = cache.write(key, Time.now.utc.iso8601, expires_in: ttl, unless_exist: true)
      return false unless claimed

      # A cache that silently drops writes (the null store) would make replay
      # protection a no-op, so refuse to continue.
      raise Unavailable, 'cache does not retain writes' unless cache.exist?(key)

      true
    end
  end
end
