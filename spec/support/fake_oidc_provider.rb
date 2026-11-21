# frozen_string_literal: true

require 'jwt'

# A fake OpenID Connect provider that ENFORCES the contract a real one does, so a
# client that gets a detail wrong fails here instead of at a real provider:
#
#   * the authorization request: response_type=code, the registered client_id and
#     redirect_uri (byte-exact), scope with openid and without offline_access, a state
#     and a nonce of at least 128 bits, PKCE with S256, and nothing else it does not know;
#   * the token request: a POST with the configured client authentication
#     (client_secret_basic with the id and the secret URL-encoded before base64, or
#     client_secret_post), grant_type=authorization_code, the registered redirect_uri,
#     a code that is valid, unused (a code works once) and the code_verifier that matches
#     the S256 challenge;
#   * the id_token: ES256, header kid, claims as a real provider sets them.
#
# Overrides let a spec make the provider misbehave (a wrong issuer, nonce, audience,
# an expired token, alg none, HS256 signed with the public key, ...).
class FakeOidcProvider
  ISSUER = 'https://op.example.com'
  CLIENT_ID = 'sign-app'
  CLIENT_SECRET = 's3cr/t +x&y%z' # characters that need URL-encoding
  REDIRECT_URI = 'https://sign.example.com/auth/oidc/callback'
  POST_LOGOUT_REDIRECT_URI = 'https://sign.example.com/'
  KID = 'fake-key-1'
  EVENT = 'http://schemas.openid.net/event/backchannel-logout'

  class ContractViolation < StandardError; end

  attr_reader :key, :authorizations, :token_requests
  attr_accessor :claims, :header, :alg, :auth_methods, :iss_in_response, :signing_key, :iss_param, :state_param, :subject

  def initialize
    @key = OpenSSL::PKey::EC.generate('prime256v1')
    @other_key = OpenSSL::PKey::EC.generate('prime256v1')
    @codes = {}
    @authorizations = []
    @token_requests = []
    @claims = {}
    @header = {}
    @alg = 'ES256'
    @auth_methods = %w[client_secret_basic client_secret_post]
    @iss_in_response = true
    @subject = SecureRandom.uuid
    @signing_key = @key
  end

  def discovery_document
    {
      issuer: ISSUER, authorization_endpoint: "#{ISSUER}/oauth2/authorize", token_endpoint: "#{ISSUER}/oauth2/token",
      jwks_uri: "#{ISSUER}/.well-known/jwks.json", userinfo_endpoint: "#{ISSUER}/userinfo",
      end_session_endpoint: "#{ISSUER}/oauth2/logout-all", response_types_supported: %w[code],
      subject_types_supported: %w[public], id_token_signing_alg_values_supported: %w[ES256],
      token_endpoint_auth_methods_supported: auth_methods, code_challenge_methods_supported: %w[S256],
      authorization_response_iss_parameter_supported: iss_in_response, scopes_supported: %w[openid email profile],
      backchannel_logout_supported: true, backchannel_logout_session_supported: true
    }
  end

  def jwk
    JSON::JWK.new(key.public_to_pem.then { |pem| OpenSSL::PKey::EC.new(pem) }, kid: KID, use: 'sig', alg: 'ES256')
  end

  # Installs the provider's endpoints into WebMock.
  def install!(webmock)
    provider = self
    webmock.stub_request(:get, "#{ISSUER}/.well-known/openid-configuration")
           .to_return { { status: 200, headers: json_headers, body: provider.discovery_document.to_json } }
    webmock.stub_request(:get, "#{ISSUER}/.well-known/jwks.json")
           .to_return { { status: 200, headers: json_headers, body: { keys: [provider.jwk] }.to_json } }
    webmock.stub_request(:post, "#{ISSUER}/oauth2/token").to_return { |request| provider.token_endpoint(request) }
  end

  # The browser's trip to the authorization endpoint: checks the request and returns the
  # URL the provider would send the browser back to.
  def authorize(url, login: {})
    uri = URI.parse(url)
    params = Rack::Utils.parse_query(uri.query)
    @authorizations << params
    check_authorization!(uri, params)

    code = SecureRandom.urlsafe_base64(24)
    @codes[code] = { params:, login:, used: false, issued_at: Time.now.to_i }

    callback = { code:, state: state_param || params['state'] }
    callback[:iss] = iss_param || ISSUER if iss_in_response && iss_param != false
    "#{REDIRECT_URI}?#{URI.encode_www_form(callback)}"
  end

  # The provider answers with an error instead of a code.
  def refuse(url, error:)
    params = Rack::Utils.parse_query(URI.parse(url).query)
    "#{REDIRECT_URI}?#{URI.encode_www_form(error:, state: params['state'], iss: ISSUER)}"
  end

  def token_endpoint(request)
    form = Rack::Utils.parse_query(request.body)
    @token_requests << { form:, authorization: request.headers['Authorization'] }
    check_client_authentication!(request, form)
    record = check_code!(form)
    id_token = mint_id_token(record)

    { status: 200, headers: json_headers.merge('Cache-Control' => 'no-store'),
      body: { access_token: SecureRandom.hex(16), token_type: 'Bearer', expires_in: 300, id_token:, scope: 'openid email' }.to_json }
  rescue ContractViolation => e
    { status: 400, headers: json_headers, body: { error: 'invalid_request', error_description: e.message }.to_json }
  end

  def base_claims(nonce)
    now = Time.now.to_i
    { iss: ISSUER, sub: subject, aud: CLIENT_ID, azp: CLIENT_ID, exp: now + 300, iat: now, auth_time: now, nonce:,
      email: 'ada@example.com', email_verified: true, name: 'Ada Lovelace', sid: 'sid-1', acr: 'urn:example:acr:1',
      amr: %w[pwd], jti: SecureRandom.uuid }
  end

  def mint_id_token(record)
    params = record[:params]
    claims = base_claims(params['nonce'])
    claims = claims.merge(auth_time: Time.now.to_i, acr: params['acr_values'], amr: %w[pwd otp mfa]) if params['max_age'] == '0'
    claims = claims.merge(record[:login]).merge(self.claims.symbolize_keys)

    sign(claims.compact, header)
  end

  def sign(claims, extra_header = {})
    headers = { kid: KID, typ: 'JWT' }.merge(extra_header.symbolize_keys)

    case alg
    when 'none'
      "#{b64(headers.merge(alg: 'none').to_json)}.#{b64(claims.to_json)}."
    when 'HS256' # the classic confusion: the public key used as an HMAC secret
      JWT.encode(claims, key.public_to_pem, 'HS256', headers)
    else
      JWT.encode(claims, signing_key, alg, headers)
    end
  end

  # A back-channel logout token as a provider sends it.
  def logout_token(overrides = nil, header: {}, **claims_override)
    now = Time.now.to_i
    claims = { iss: ISSUER, aud: CLIENT_ID, iat: now, exp: now + 120, jti: SecureRandom.uuid, sub: subject, sid: 'sid-1',
               events: { EVENT => {} } }
    claims = claims.merge((overrides || {}).symbolize_keys).merge(claims_override)

    JWT.encode(claims.compact, signing_key, 'ES256', { kid: KID, typ: 'logout+jwt' }.merge(header.symbolize_keys))
  end

  def use_foreign_key!
    @signing_key = @other_key
  end

  private

  def check_authorization!(uri, params)
    violation!('authorization endpoint') unless "#{uri.scheme}://#{uri.host}#{uri.path}" == "#{ISSUER}/oauth2/authorize"
    violation!('response_type must be code') unless params['response_type'] == 'code'
    violation!('unknown client_id') unless params['client_id'] == CLIENT_ID
    violation!('redirect_uri is not the registered one') unless params['redirect_uri'] == REDIRECT_URI
    scopes = params['scope'].to_s.split
    violation!('scope must contain openid') unless scopes.include?('openid')
    violation!('offline_access must not be requested') if scopes.include?('offline_access')
    violation!('state needs at least 128 bits') unless params['state'].to_s.length >= 22
    violation!('nonce needs at least 128 bits') unless params['nonce'].to_s.length >= 22
    violation!('PKCE S256 is required') unless params['code_challenge_method'] == 'S256' && params['code_challenge'].present?
    unknown = params.keys - %w[response_type client_id redirect_uri scope state nonce code_challenge code_challenge_method
                               max_age acr_values prompt]
    violation!("unknown parameter #{unknown.first}") if unknown.any?
  end

  def check_client_authentication!(request, form)
    header = request.headers['Authorization'].to_s

    if header.start_with?('Basic ')
      violation!('client_secret_basic is not enabled') unless auth_methods.include?('client_secret_basic')
      id, secret = Base64.strict_decode64(header.delete_prefix('Basic ')).split(':', 2)
      violation!('client id/secret must be URL-encoded') unless URI.decode_www_form_component(id.to_s) == CLIENT_ID &&
                                                                URI.decode_www_form_component(secret.to_s) == CLIENT_SECRET &&
                                                                secret == URI.encode_www_form_component(CLIENT_SECRET)
    else
      violation!('client_secret_post is not enabled') unless auth_methods.include?('client_secret_post')
      violation!('bad client credentials') unless form['client_id'] == CLIENT_ID && form['client_secret'] == CLIENT_SECRET
    end
  end

  def check_code!(form)
    violation!('grant_type must be authorization_code') unless form['grant_type'] == 'authorization_code'
    record = @codes[form['code']]
    violation!('unknown code') unless record
    violation!('code already used') if record[:used]
    record[:used] = true
    violation!('code expired') if Time.now.to_i - record[:issued_at] > 60
    violation!('redirect_uri differs') unless form['redirect_uri'] == REDIRECT_URI
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(form['code_verifier'].to_s), padding: false)
    violation!('code_verifier does not match') unless challenge == record[:params]['code_challenge']
    record
  end

  def violation!(message)
    raise ContractViolation, message
  end

  def b64(text)
    Base64.urlsafe_encode64(text, padding: false)
  end

  def json_headers
    { 'Content-Type' => 'application/json' }
  end
end
