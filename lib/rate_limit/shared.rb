# frozen_string_literal: true

module RateLimit
  # Rate-limit counters shared by every app process, kept in the Redis that Sidekiq
  # already uses (REDIS_URL), so a limit holds however many servers run.
  #
  # A fixed window: the counter lives under a key made of the name and the window
  # number and is created and expired atomically (one Lua call).
  #
  #   * HOSTED_MODE=true: the store is required. If Redis cannot be reached the
  #     call raises Extensions::RateLimitUnavailable and the action is refused
  #     (fail closed).
  #   * otherwise: the same counters, but if Redis cannot be reached the call falls
  #     back to the per-process store (RateLimit.call), as stock does.
  module Shared
    SCRIPT = <<~LUA
      local v = redis.call('INCR', KEYS[1])
      if v == 1 then redis.call('EXPIRE', KEYS[1], ARGV[1]) end
      return v
    LUA

    STORE_ERRORS = [RedisClient::Error, SystemCallError, SocketError, IOError, Timeout::Error].freeze

    module_function

    # @raise [RateLimit::LimitApproached] over the limit
    # @raise [Extensions::RateLimitUnavailable] hosted mode and the store is down
    def call(key, limit:, ttl:)
      value = increment(key, ttl.to_i)

      raise LimitApproached if value > limit

      true
    rescue *STORE_ERRORS => e
      raise Extensions::RateLimitUnavailable, e.class.name if Extensions.hosted?

      Rails.logger.warn("RateLimit::Shared store unavailable, using the process store: #{e.class}")
      RateLimit.call(key, limit:, ttl:, enabled: true)
    end

    def increment(key, ttl)
      window = Time.now.to_i / ttl

      Sidekiq.redis { |conn| conn.call('EVAL', SCRIPT, 1, "dsign:rl:#{key}:#{window}", ttl).to_i }
    end
  end
end
