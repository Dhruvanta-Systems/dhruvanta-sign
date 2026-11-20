# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'jwt'

# Fetches and caches a JSON Web Key Set.
#
#   * The URL defaults to JWT_SSO_JWKS_URL (see {JwtSso::Config}).
#   * A successful fetch is cached in `Rails.cache` for five minutes.
#   * A `kid` that is not in the cached set forces one refetch before it is
#     reported absent, which handles a key rotation at the issuer.
#   * Network failures and non-2xx responses raise {JwksUnreachable}; an invalid
#     document raises {JwksMalformed}.
module JwtSso
  class JwksClient
    class JwksError < StandardError; end
    class JwksUnreachable < JwksError; end
    class JwksMalformed < JwksError; end

    CACHE_KEY_PREFIX = 'jwt_sso_jwks'
    CACHE_TTL = 5.minutes
    REQUEST_TIMEOUT = 5

    def initialize(jwks_url: nil, cache: Rails.cache, http: nil)
      @jwks_url = jwks_url || JwtSso::Config.jwks_url
      @cache = cache
      @http = http
    end

    attr_reader :jwks_url

    # Find the public-key JWK for the given `kid`. Forces one refetch
    # on a cache miss before reporting absent.
    #
    # @param kid [String] the kid header value from the SignedJWT
    # @return [Hash, nil] the JWK (Ruby hash form) for `kid`, or nil
    def find_key(kid)
      return nil if kid.nil? || kid.empty?

      jwks = current_jwks
      match = locate(jwks, kid)
      return match if match

      Rails.logger.info("jwks-cache-miss kid=#{kid} forcing refetch")
      jwks = force_refetch!
      locate(jwks, kid)
    end

    # Drop the cache entry. Public for tests + operator hot-reload.
    def reset_cache!
      @cache.delete(cache_key)
    end

    # Force a fresh HTTP fetch + cache write.
    #
    # @raise [JwtSso::JwksClient::JwksUnreachable] on 5xx / network
    # @raise [JwtSso::JwksClient::JwksMalformed] on JSON / JWKS parse
    def force_refetch!
      raw = fetch_jwks_json
      jwks = parse_jwks(raw)
      @cache.write(cache_key, jwks, expires_in: CACHE_TTL)
      Rails.logger.info("jwks-fetched url=#{@jwks_url} keys=#{jwks['keys']&.size || 0}")
      jwks
    end

    private

    def current_jwks
      cached = @cache.read(cache_key)
      return cached if cached

      force_refetch!
    end

    def cache_key
      "#{CACHE_KEY_PREFIX}:#{@jwks_url}"
    end

    # Hits the configured JWKS URL and returns the response body.
    def fetch_jwks_json
      uri = URI.parse(@jwks_url)
      raise JwksUnreachable, "jwks-bad-url: #{@jwks_url}" unless %w[http https].include?(uri.scheme)

      http = @http || build_http(uri)
      request = Net::HTTP::Get.new(uri.request_uri, 'Accept' => 'application/json')

      response = http.request(request)
      raise JwksUnreachable, "jwks-http-#{response.code}" unless response.is_a?(Net::HTTPSuccess)

      response.body
    rescue Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout, SocketError => e
      raise JwksUnreachable, "jwks-io: #{e.message}"
    end

    def build_http(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = REQUEST_TIMEOUT
      http.read_timeout = REQUEST_TIMEOUT
      http
    end

    def parse_jwks(raw)
      parsed = JSON.parse(raw)
      raise JwksMalformed, 'jwks-no-keys-array' unless parsed.is_a?(Hash) && parsed['keys'].is_a?(Array)

      parsed
    rescue JSON::ParserError => e
      raise JwksMalformed, "jwks-json: #{e.message}"
    end

    def locate(jwks, kid)
      jwks['keys'].find { |k| k['kid'] == kid }
    end
  end
end
