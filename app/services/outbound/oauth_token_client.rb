# frozen_string_literal: true

require 'faraday'
require 'json'
require 'uri'

module Outbound
  # Generic OAuth2 client-credentials token client.
  #
  # Fetches and caches an access token for server-to-server calls:
  #
  #   * POST OAUTH_TOKEN_URL, application/x-www-form-urlencoded
  #   * grant_type=client_credentials, client_id=OAUTH_CLIENT_ID and the client
  #     secret (from the file at OAUTH_CLIENT_SECRET_PATH, or OAUTH_CLIENT_SECRET)
  #   * `scope` (OAUTH_SCOPE) and `audience` (OAUTH_AUDIENCE) are sent only when set
  #
  # Tokens are cached in `Rails.cache` per audience and refreshed
  # OAUTH_TOKEN_REFRESH_BEFORE_SECONDS (default 60) before they expire, so callers
  # never get a token that is about to lapse.
  #
  # Retry policy: 3 attempts with 250ms / 1s / 4s backoff on 429, 5xx and network
  # errors; any other 4xx fails immediately with {TokenError}.
  #
  # A structured `audit.oauth_token` JSON line is logged on every cache miss or
  # refresh (cache hits are silent). The token itself is never logged.
  #
  # Test seam: the `cache:` and `http:` constructor arguments.
  class OauthTokenClient
    DEFAULT_REFRESH_BEFORE_SECONDS = 60
    DEFAULT_MAX_ATTEMPTS = 3
    DEFAULT_HTTP_TIMEOUT_SECONDS = 5
    BACKOFF_SECONDS = [0.25, 1.0, 4.0].freeze

    CACHE_STATUS_HIT     = 'HIT'
    CACHE_STATUS_MISS    = 'MISS'
    CACHE_STATUS_REFRESH = 'REFRESH'

    class TokenError < StandardError; end

    CachedToken = Struct.new(:access_token, :expires_at, keyword_init: true)

    def initialize(cache: Rails.cache, http: nil, logger: Rails.logger)
      @cache = cache
      @http = http
      @logger = logger
    end

    # Returns a valid bearer token, minting a fresh one on a cache miss or near
    # expiry. `audience` defaults to OAUTH_AUDIENCE and is optional. Raises
    # {TokenError} on misconfiguration, exhausted retries, network failure or a
    # malformed token endpoint response.
    def access_token(audience = ENV['OAUTH_AUDIENCE'].to_s.strip)
      audience = audience.to_s

      cached = read_cache(audience)
      now = Time.now.utc
      if cached && cached.expires_at > now + refresh_before_seconds
        emit_audit(audience, CACHE_STATUS_HIT, nil)
        return cached.access_token
      end

      cache_status = cached.nil? ? CACHE_STATUS_MISS : CACHE_STATUS_REFRESH
      minted = mint(audience)
      write_cache(audience, minted)
      emit_audit(audience, cache_status, jwt_jti(minted.access_token))
      minted.access_token
    end

    # Drops the cached token for `audience`.
    def invalidate(audience = ENV['OAUTH_AUDIENCE'].to_s.strip)
      @cache.delete(cache_key(audience.to_s))
    end

    private

    def mint(audience)
      url = token_url
      raise TokenError, 'OAUTH_TOKEN_URL is required' if blank?(url)

      client_id = ENV['OAUTH_CLIENT_ID'].to_s
      raise TokenError, 'OAUTH_CLIENT_ID is required' if blank?(client_id)

      secret = read_secret
      form = { grant_type: 'client_credentials', client_id: client_id, client_secret: secret }
      form[:audience] = audience unless blank?(audience)
      form[:scope] = oauth_scope unless blank?(oauth_scope)
      body = URI.encode_www_form(form)

      attempts = max_attempts
      last_error = nil
      attempts.times do |attempt|
        sleep(BACKOFF_SECONDS[attempt - 1]) if attempt.positive?
        begin
          resp = perform_request(url, body)
          status = resp.status.to_i
          return parse_token_response(resp.body, audience) if (200..299).cover?(status)

          if status == 429 || (500..599).cover?(status)
            last_error = "token endpoint #{status} (audience=#{audience})"
            next
          end
          raise TokenError,
                "token endpoint rejected token request HTTP #{status} (audience=#{audience}): " \
                "#{truncate(resp.body.to_s)}"
        rescue Faraday::TimeoutError => e
          last_error = "timeout: #{e.message}"
          next
        rescue Faraday::ConnectionFailed, Faraday::Error => e
          last_error = "io: #{e.message}"
          next
        end
      end

      raise TokenError, "token endpoint retries exhausted — last_error=#{last_error}"
    end

    def perform_request(full_url, body)
      conn = @http || default_http
      conn.post(full_url) do |req|
        req.headers['Content-Type'] = 'application/x-www-form-urlencoded'
        req.headers['Accept'] = 'application/json'
        req.options.timeout = http_timeout_seconds
        req.options.open_timeout = http_timeout_seconds
        req.body = body
      end
    end

    def default_http
      Faraday.new do |f|
        f.adapter Faraday.default_adapter
      end
    end

    def parse_token_response(body, audience)
      json =
        begin
          JSON.parse(body.to_s)
        rescue JSON::ParserError => e
          raise TokenError, "token endpoint returned malformed JSON (audience=#{audience}): #{e.message}"
        end
      access_token = json['access_token'].to_s
      expires_in = json['expires_in']
      raise TokenError, "token endpoint response missing access_token (audience=#{audience})" if blank?(access_token)
      unless expires_in.is_a?(Numeric)
        raise TokenError, "token endpoint response missing numeric expires_in (audience=#{audience})"
      end

      CachedToken.new(
        access_token: access_token,
        expires_at: Time.now.utc + expires_in.to_i
      )
    end

    def read_cache(audience)
      raw = @cache.read(cache_key(audience))
      return nil if raw.nil?

      # `Rails.cache` may roundtrip through marshalling — accept both
      # CachedToken structs and plain hashes (when MemoryStore swaps).
      return raw if raw.is_a?(CachedToken)
      return nil unless raw.is_a?(Hash)

      CachedToken.new(
        access_token: raw['access_token'] || raw[:access_token],
        expires_at: raw['expires_at'] || raw[:expires_at]
      )
    rescue StandardError
      nil
    end

    def write_cache(audience, token)
      ttl = [(token.expires_at - Time.now.utc).to_i - refresh_before_seconds, 1].max
      @cache.write(cache_key(audience), token, expires_in: ttl)
    rescue StandardError => e
      @logger&.warn("[service-token-cache-write] failed audience=#{audience} reason=#{e.message}")
    end

    def cache_key(audience)
      "outbound:oauth_token:#{audience}"
    end

    def emit_audit(audience, cache_status, jti)
      event = {
        event_code: 'OUTBOUND_TOKEN_MINTED',
        actor_user_id: nil,
        target_id_type: 'OAUTH_TOKEN',
        target_id_hash: nil,
        provider_ref: jti || 'unknown',
        verified_at: Time.now.utc.iso8601,
        failure_reason: nil,
        emitted_at: Time.now.utc.iso8601,
        audience: audience,
        cache_status: cache_status
      }
      @logger&.info("audit.oauth_token #{JSON.generate(event)}")
    rescue StandardError => e
      @logger&.warn("[service-token-audit-emit] failed reason=#{e.message}")
    end

    def jwt_jti(token)
      parts = token.to_s.split('.')
      return 'unknown' if parts.length < 2

      payload_json = JSON.parse(Base64.urlsafe_decode64(pad_b64(parts[1])))
      payload_json['jti'].to_s.empty? ? 'unknown' : payload_json['jti']
    rescue StandardError
      'unknown'
    end

    def pad_b64(value)
      value + ('=' * ((4 - (value.length % 4)) % 4))
    end

    def token_url
      ENV['OAUTH_TOKEN_URL'].to_s
    end

    def oauth_scope
      ENV['OAUTH_SCOPE'].to_s.strip
    end

    def read_secret
      path = ENV['OAUTH_CLIENT_SECRET_PATH'].to_s
      if blank?(path)
        inline = ENV['OAUTH_CLIENT_SECRET'].to_s.strip
        raise TokenError, 'OAUTH_CLIENT_SECRET_PATH or OAUTH_CLIENT_SECRET is required' if inline.empty?

        return inline
      end
      raise TokenError, "client secret file not found at #{path}" unless File.exist?(path)

      secret = File.read(path).strip
      raise TokenError, "client secret file is empty at #{path}" if secret.empty?

      secret
    end

    def refresh_before_seconds
      ENV.fetch('OAUTH_TOKEN_REFRESH_BEFORE_SECONDS', DEFAULT_REFRESH_BEFORE_SECONDS).to_i
    end

    def max_attempts
      [ENV.fetch('OAUTH_TOKEN_MAX_ATTEMPTS', DEFAULT_MAX_ATTEMPTS).to_i, 1].max
    end

    def http_timeout_seconds
      ENV.fetch('OAUTH_TOKEN_HTTP_TIMEOUT_SECONDS', DEFAULT_HTTP_TIMEOUT_SECONDS).to_i
    end

    def truncate(value)
      value.length > 256 ? "#{value[0, 256]}..." : value
    end

    def blank?(value)
      value.nil? || value.to_s.empty?
    end
  end
end
