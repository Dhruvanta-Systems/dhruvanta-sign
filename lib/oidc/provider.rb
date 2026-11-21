# frozen_string_literal: true

module Oidc
  # The provider's discovery document and the OpenIDConnect::Client built from it.
  # Discovery is cached for an hour.
  module Provider
    TTL = 1.hour

    @mutex = Mutex.new
    @cached = nil

    module_function

    # @return [OpenIDConnect::Discovery::Provider::Config::Response]
    def config
      @mutex.synchronize do
        if @cached.nil? || @cached[:issuer] != Config.issuer || Time.current - @cached[:at] > TTL
          @cached = { issuer: Config.issuer, at: Time.current, config: discover }
        end

        @cached[:config]
      end
    end

    def reset!
      @mutex.synchronize { @cached = nil }
    end

    def client
      document = config

      OpenIDConnect::Client.new(identifier: Config.client_id, secret: Config.client_secret,
                                redirect_uri: Config.redirect_uri,
                                authorization_endpoint: document.authorization_endpoint,
                                token_endpoint: document.token_endpoint,
                                userinfo_endpoint: document.userinfo_endpoint)
    end

    # :basic (client_secret_basic) unless the provider does not offer it.
    def token_auth_method
      return Config.token_auth_method.to_sym if Config.token_auth_method

      supported = Array(config.token_endpoint_auth_methods_supported)

      supported.empty? || supported.include?('client_secret_basic') ? :basic : :post
    end

    def end_session_endpoint
      config.end_session_endpoint.presence || config.raw['end_session_endpoint'].presence
    end

    # RFC 9207: does the provider promise an `iss` in authorization responses?
    def iss_in_response_required?
      config.raw['authorization_response_iss_parameter_supported'] == true
    end

    def discover
      document = OpenIDConnect::Discovery::Provider::Config.discover!(Config.issuer)
      raise Error.new('discovery_issuer_mismatch', :service_unavailable) unless document.issuer == Config.issuer

      document
    rescue Error
      raise
    rescue StandardError => e
      Rails.logger.warn("Oidc discovery failed: #{e.class}")
      raise Error.new('discovery_failed', :service_unavailable, 'The sign-in service is unavailable.')
    end
    private_class_method :discover
  end
end
