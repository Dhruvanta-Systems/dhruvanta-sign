# frozen_string_literal: true

module Oidc
  # Settings of the OpenID Connect relying party used with AUTH_MODE=external. Every
  # value comes from the environment and is read on each call; there is no default
  # issuer, client or secret.
  #
  #   OIDC_ISSUER                   the issuer URL, exactly as the provider publishes it
  #                                 (discovery is read from <issuer>/.well-known/openid-configuration)
  #   OIDC_CLIENT_ID                this app's client id at the provider
  #   OIDC_CLIENT_SECRET_FILE       path of a file holding the client secret (never the
  #                                 secret itself in the environment)
  #   OIDC_REDIRECT_URI             the registered redirect URI (default: this app's
  #                                 /auth/oidc/callback)
  #   OIDC_POST_LOGOUT_REDIRECT_URI the registered post-logout URI (default: this app's root)
  #   OIDC_SCOPES                   default "openid email profile" ("offline_access" is
  #                                 never requested: there are no refresh tokens)
  #   OIDC_TOKEN_AUTH_METHOD        "basic" (client_secret_basic) or "post"
  #                                 (client_secret_post). Default: basic, or post when the
  #                                 provider does not advertise basic.
  #   OIDC_ID_TOKEN_ALGS            accepted id_token signature algorithms, default
  #                                 "ES256 ES384 RS256 PS256". "none" and HMAC are never accepted.
  #   OIDC_ALLOW_SIGNUP             "false" refuses a person with no user and no invitation
  #   OIDC_SESSION_MAX_AGE_SECONDS  longest a sign-in lasts (default 43200, 12 hours)
  #   OIDC_MAX_ID_TOKEN_AGE_SECONDS oldest an id_token may be when it arrives (default 600)
  #   OIDC_STEP_UP_ACR              acr value requested for a sensitive action (blank: no step-up)
  #   OIDC_STEP_UP_ACR_ORDER        comma list of acr values, lowest first; a result counts
  #                                 when its rank is at least that of OIDC_STEP_UP_ACR
  #   OIDC_STEP_UP_ACTIONS          comma list of actions that need step-up; see Oidc::StepUp::ACTIONS
  module Config
    DEFAULT_SCOPES = %w[openid email profile].freeze
    DEFAULT_ALGS = %w[ES256 ES384 RS256 PS256].freeze
    NEVER_ALGS = %w[none HS256 HS384 HS512].freeze
    DEFAULT_SESSION_MAX_AGE = 43_200
    DEFAULT_ID_TOKEN_AGE = 600
    CLOCK_SKEW = 60

    ConfigError = Class.new(StandardError)

    module_function

    def issuer = env('OIDC_ISSUER')

    def client_id = env('OIDC_CLIENT_ID')

    def secret_file = env('OIDC_CLIENT_SECRET_FILE')

    def enabled?
      issuer.present? && client_id.present? && secret_file.present?
    end

    # nil when the secret file can be read and is not empty, else a sentence.
    def secret_file_error
      return 'OIDC_CLIENT_SECRET_FILE is not set' if secret_file.blank?
      return "the client secret file #{secret_file} is not readable" unless File.file?(secret_file) && File.readable?(secret_file)
      return "the client secret file #{secret_file} is empty" if File.read(secret_file).strip.empty?

      nil
    end

    def client_secret
      error = secret_file_error
      raise ConfigError, error if error

      File.read(secret_file).strip
    end

    def redirect_uri
      env('OIDC_REDIRECT_URI').presence ||
        Rails.application.routes.url_helpers.oidc_callback_url(**Docuseal.default_url_options)
    end

    def post_logout_redirect_uri
      env('OIDC_POST_LOGOUT_REDIRECT_URI').presence ||
        Rails.application.routes.url_helpers.root_url(**Docuseal.default_url_options)
    end

    def scopes
      list = env('OIDC_SCOPES').split.presence || DEFAULT_SCOPES
      list -= ['offline_access']
      list.include?('openid') ? list : ['openid', *list]
    end

    def token_auth_method
      value = env('OIDC_TOKEN_AUTH_METHOD').downcase
      %w[basic post].include?(value) ? value : nil
    end

    def allowed_algs
      list = env('OIDC_ID_TOKEN_ALGS').split.presence || DEFAULT_ALGS

      list - NEVER_ALGS
    end

    def allow_signup? = env('OIDC_ALLOW_SIGNUP').downcase != 'false'

    def session_max_age = positive_int('OIDC_SESSION_MAX_AGE_SECONDS', DEFAULT_SESSION_MAX_AGE)

    def max_id_token_age = positive_int('OIDC_MAX_ID_TOKEN_AGE_SECONDS', DEFAULT_ID_TOKEN_AGE)

    def step_up_acr = env('OIDC_STEP_UP_ACR')

    def step_up_acr_order = env('OIDC_STEP_UP_ACR_ORDER').split(',').map(&:strip).compact_blank

    def step_up_actions = env('OIDC_STEP_UP_ACTIONS').split(',').map(&:strip).compact_blank

    # Does `action` need a fresh second-factor proof?
    def step_up?(action)
      step_up_acr.present? && step_up_actions.include?(action.to_s)
    end

    # Is `acr` at least as strong as the required one? With no order configured the
    # values must be equal.
    def acr_satisfies?(acr)
      order = step_up_acr_order
      return acr.to_s == step_up_acr if order.empty? || order.exclude?(step_up_acr)

      rank = order.index(acr.to_s)
      !rank.nil? && rank >= order.index(step_up_acr)
    end

    def env(name, default = '')
      value = ENV.fetch(name, nil).to_s.strip

      value.empty? ? default : value
    end

    def positive_int(name, default)
      value = env(name).to_i

      value.positive? ? value : default
    end
  end
end
