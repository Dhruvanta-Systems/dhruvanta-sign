# frozen_string_literal: true

require 'tempfile'

# Everything an OIDC spec needs: the fake provider installed into WebMock, the client
# configured from the environment (the secret in a file), and a helper that walks a
# browser through the real redirects.
module OidcHelpers
  def oidc_env(extra = {})
    {
      'OIDC_ISSUER' => FakeOidcProvider::ISSUER, 'OIDC_CLIENT_ID' => FakeOidcProvider::CLIENT_ID,
      'OIDC_CLIENT_SECRET_FILE' => oidc_secret_file.path, 'OIDC_REDIRECT_URI' => FakeOidcProvider::REDIRECT_URI,
      'OIDC_POST_LOGOUT_REDIRECT_URI' => FakeOidcProvider::POST_LOGOUT_REDIRECT_URI
    }.merge(extra)
  end

  def oidc_secret_file
    @oidc_secret_file ||= Tempfile.new('oidc-secret').tap do |file|
      file.write("#{FakeOidcProvider::CLIENT_SECRET}\n")
      file.flush
    end
  end

  def fake_provider
    @fake_provider ||= FakeOidcProvider.new.tap { |provider| provider.install!(self) }
  end

  # Signs an existing user in through the fake provider (so there is a registry row, as
  # in production): the user is bound to the provider's subject first.
  def sign_in_via_oidc(user)
    user.update!(sso_issuer: FakeOidcProvider::ISSUER, sso_subject: fake_provider.subject)
    fake_provider.claims = fake_provider.claims.merge(email: user.email)

    oidc_sign_in
    fake_provider.subject = SecureRandom.uuid # the next call to this helper is another person
  end

  # Starts a sign-in, lets the provider authorize it and returns the callback path.
  def oidc_authorize(login: {}, return_to: nil)
    get '/auth/oidc/start', params: { return_to: }.compact
    expect(response).to have_http_status(:found)

    callback_url = fake_provider.authorize(response.location, login:)
    URI.parse(callback_url).then { |uri| "#{uri.path}?#{uri.query}" }
  end

  # The whole sign-in. Returns the response of the callback.
  def oidc_sign_in(login: {})
    get oidc_authorize(login:)
    response
  end
end

RSpec.configure do |config|
  config.include OidcHelpers, :oidc

  config.before(:each, :oidc) do
    Oidc::Provider.reset!
    Oidc::Jwks.reset!
    fake_provider # install the provider's endpoints before the first request
  end
end
