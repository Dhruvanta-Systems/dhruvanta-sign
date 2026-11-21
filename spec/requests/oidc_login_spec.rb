# frozen_string_literal: true

require 'rails_helper'

# AUTH_MODE=external is an OpenID Connect relying party. These specs run it against a
# fake provider that enforces the real protocol (see spec/support/fake_oidc_provider.rb).
describe 'OpenID Connect sign-in', :oidc do
  let(:fake) { fake_provider }
  let(:issuer) { FakeOidcProvider::ISSUER }

  around do |example|
    with_routes_for(oidc_env('AUTH_MODE' => 'external')) { example.run }
  end

  def sign_in_user
    oidc_sign_in
    User.find_by!(sso_subject: fake.subject)
  end

  describe 'a good sign-in' do
    it 'signs a new person in, binds the user to (issuer, sub) and opens a registry row' do
      oidc_sign_in

      expect(response).to redirect_to('/')
      user = User.find_by!(sso_subject: fake.subject)
      expect(user).to have_attributes(sso_issuer: issuer, email: 'ada@example.com', role: 'admin')

      registry = user.oidc_sessions.sole
      expect(registry).to have_attributes(issuer:, sub: fake.subject, sid: 'sid-1', acr: 'urn:example:acr:1', amr: %w[pwd])
      expect(registry.auth_time).to be_within(10.seconds).of(Time.current)
      expect(registry.revoked_at).to be_nil

      get '/settings/profile'
      expect(response).to have_http_status(:ok)
    end

    it 'sends the authorization request a real provider requires: code + PKCE S256 + state + nonce, no offline_access' do
      oidc_sign_in

      params = fake.authorizations.sole
      expect(params).to include('response_type' => 'code', 'client_id' => 'sign-app', 'code_challenge_method' => 'S256')
      expect(params['scope'].split).to contain_exactly('openid', 'email', 'profile')
      expect(params['state'].length).to be >= 43
      expect(params['nonce'].length).to be >= 43
      expect(params).not_to include('max_age', 'acr_values', 'prompt')
    end

    it 'authenticates at the token endpoint with client_secret_basic, id and secret URL-encoded' do
      oidc_sign_in

      request = fake.token_requests.sole
      expect(request[:authorization]).to start_with('Basic ')
      id, secret = Base64.strict_decode64(request[:authorization].delete_prefix('Basic ')).split(':', 2)
      expect([id, secret]).to eq(['sign-app', URI.encode_www_form_component(FakeOidcProvider::CLIENT_SECRET)])
      expect(request[:form]).to include('grant_type' => 'authorization_code', 'redirect_uri' => FakeOidcProvider::REDIRECT_URI)
      expect(request[:form]['code_verifier'].length).to be >= 43
      expect(request[:form]).not_to include('client_secret')
    end

    it 'falls back to client_secret_post when the provider does not offer basic' do
      fake.auth_methods = %w[client_secret_post]

      oidc_sign_in

      expect(response).to redirect_to('/')
      expect(fake.token_requests.sole[:authorization]).to be_nil
      expect(fake.token_requests.sole[:form]).to include('client_secret' => FakeOidcProvider::CLIENT_SECRET)
    end

    it 'honours OIDC_TOKEN_AUTH_METHOD=post' do
      with_env('OIDC_TOKEN_AUTH_METHOD' => 'post') { oidc_sign_in }

      expect(fake.token_requests.sole[:form]).to include('client_secret')
    end

    it 'returns to the page the person came from, and only a path on this app' do
      get oidc_authorize(return_to: '/settings/profile')
      expect(response).to redirect_to('/settings/profile')

      get oidc_authorize(return_to: 'https://evil.example.net/')
      expect(response).to redirect_to('/')

      get oidc_authorize(return_to: '//evil.example.net')
      expect(response).to redirect_to('/')
    end

    it 'reads the client secret from the file, never from the environment' do
      expect(ENV.fetch('OIDC_CLIENT_SECRET', nil)).to be_nil

      oidc_sign_in

      expect(response).to redirect_to('/')
    end

    it 'does not keep refresh tokens or access tokens' do
      oidc_sign_in

      expect(session.to_h.keys.map(&:to_s)).not_to include('refresh_token', 'access_token')
    end

    it 'signs the same person into the same user every time' do
      oidc_sign_in
      delete '/auth/oidc/logout'
      oidc_sign_in

      expect(User.where(sso_subject: fake.subject).count).to eq(1)
      expect(Account.count).to eq(1)
    end

    it 'sends a signed-out visitor to the provider, not to a local page' do
      get '/settings/profile'
      expect(response).to redirect_to('/auth/oidc/start')

      get oidc_authorize
      expect(response).to redirect_to('/settings/profile') # back to the page they asked for
    end
  end

  describe 'the authorization response' do
    it 'refuses a state that is not the one it stored' do
      fake.state_param = 'forged-state-value-forged-state-value'

      oidc_sign_in

      expect(response).to have_http_status(:bad_request)
      expect(User.count).to eq(0)
    end

    it 'refuses a callback that was not asked for, and a second use of the same callback' do
      path = oidc_authorize

      get path
      expect(response).to have_http_status(:found)

      delete '/auth/oidc/logout'
      get path
      expect(response).to have_http_status(:bad_request)
    end

    it 'uses up the login attempt on a wrong state: the right callback afterwards is refused' do
      path = oidc_authorize

      get '/auth/oidc/callback', params: { code: 'whatever', state: 'wrong-state-wrong-state-wrong-state' }
      expect(response).to have_http_status(:bad_request)

      get path
      expect(response).to have_http_status(:bad_request)
      expect(response.body).to include('no login in progress')
      expect(User.count).to eq(0)
    end

    it 'refuses an iss that is not the issuer (RFC 9207)' do
      fake.iss_param = 'https://evil.example.net'

      oidc_sign_in

      expect(response).to have_http_status(:bad_request)
      expect(response.body).to include('issuer mismatch')
      expect(fake.token_requests).to be_empty
    end

    it 'refuses a missing iss when the provider promises one' do
      fake.iss_param = false

      oidc_sign_in

      expect(response).to have_http_status(:bad_request)
      expect(fake.token_requests).to be_empty
    end

    it 'accepts a missing iss when the provider makes no such promise' do
      fake.iss_in_response = false

      oidc_sign_in

      expect(response).to redirect_to('/')
    end

    it 'shows access_denied as "not signed in", not a crash' do
      get '/auth/oidc/start'
      get(fake.refuse(response.location, error: 'access_denied').then { |url| URI.parse(url).request_uri })

      expect(response).to have_http_status(:forbidden)
      expect(response.body).to include('Sign-in failed').and include('/auth/oidc/start')
      expect(User.count).to eq(0)
    end

    it 'shows login_required as "not signed in"' do
      get '/auth/oidc/start'
      get(fake.refuse(response.location, error: 'login_required').then { |url| URI.parse(url).request_uri })

      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses a callback with no code' do
      get '/auth/oidc/start'
      state = Rack::Utils.parse_query(URI.parse(response.location).query)['state']

      get '/auth/oidc/callback', params: { state:, iss: issuer }

      expect(response).to have_http_status(:bad_request)
    end

    it 'treats a refused token request as a failed sign-in' do
      path = oidc_authorize
      allow(fake).to receive(:check_code!).and_raise(FakeOidcProvider::ContractViolation, 'code expired')

      get path

      expect(response).to have_http_status(:bad_gateway)
      expect(User.count).to eq(0)
    end
  end

  describe 'the id_token' do
    def expect_refused(status = :bad_request)
      oidc_sign_in

      expect(response).to have_http_status(status)
      expect(User.count).to eq(0)
      expect(OidcSession.count).to eq(0)
    end

    it 'refuses a nonce that is not this login\'s' do
      fake.claims = { nonce: 'another-logins-nonce-another-logins-nonce' }

      expect_refused
      expect(response.body).to include('nonce mismatch')
    end

    it 'refuses a token with no nonce' do
      fake.claims = { nonce: nil }

      expect_refused
    end

    it 'refuses another issuer' do
      fake.claims = { iss: 'https://evil.example.net' }

      expect_refused
      expect(response.body).to include('issuer mismatch')
    end

    it 'refuses an audience that is not this client' do
      fake.claims = { aud: 'another-client', azp: nil }

      expect_refused
      expect(response.body).to include('audience mismatch')
    end

    it 'refuses several audiences when azp is not this client' do
      fake.claims = { aud: %w[sign-app another-client], azp: 'another-client' }

      expect_refused
      expect(response.body).to include('authorized party mismatch')
    end

    it 'refuses several audiences with no azp' do
      fake.claims = { aud: %w[sign-app another-client], azp: nil }

      expect_refused
    end

    it 'accepts several audiences when azp is this client' do
      fake.claims = { aud: %w[sign-app another-client], azp: 'sign-app' }

      oidc_sign_in

      expect(response).to redirect_to('/')
    end

    it 'refuses an expired token' do
      fake.claims = { exp: 5.minutes.ago.to_i, iat: 10.minutes.ago.to_i }

      expect_refused
      expect(response.body).to include('token expired')
    end

    it 'refuses a token issued in the future' do
      fake.claims = { iat: 10.minutes.from_now.to_i, exp: 20.minutes.from_now.to_i }

      expect_refused
    end

    it 'refuses a token issued long ago' do
      fake.claims = { iat: 2.hours.ago.to_i, exp: 1.hour.from_now.to_i }

      expect_refused
      expect(response.body).to include('token too old')
    end

    it 'refuses a token with no expiry' do
      fake.claims = { exp: nil }

      expect_refused
    end

    it 'refuses alg none' do
      fake.alg = 'none'

      expect_refused
      expect(response.body).to include('invalid token alg')
    end

    it 'refuses HS256 signed with the provider\'s public key (algorithm confusion)' do
      fake.alg = 'HS256'

      expect_refused
      expect(response.body).to include('invalid token alg')
    end

    it 'refuses HS256 even when the deployment lists it as allowed' do
      fake.alg = 'HS256'

      with_env('OIDC_ID_TOKEN_ALGS' => 'ES256 HS256 none') { expect_refused }
      expect(response.body).to include('invalid token alg')
    end

    it 'refuses a signature made with another key' do
      fake.use_foreign_key!

      expect_refused
      expect(response.body).to include('invalid token signature')
    end

    it 'refuses a token whose kid is not in the key set' do
      fake.header = { kid: 'unknown-key' }

      expect_refused
      expect(response.body).to include('unknown token key')
    end

    it 'does not follow a jku header' do
      fake.header = { jku: 'https://evil.example.net/keys.json' }
      fake.use_foreign_key!

      expect_refused
      expect(a_request(:get, 'https://evil.example.net/keys.json')).not_to have_been_made
    end

    it 'refuses email_verified=false' do
      fake.claims = { email_verified: false }

      expect_refused(:forbidden)
      expect(response.body).to include('email not verified')
    end

    it 'refuses email_verified as a string, and a missing claim' do
      fake.claims = { email_verified: 'true' }
      expect_refused(:forbidden)

      fake.claims = { email_verified: nil }
      oidc_sign_in
      expect(response).to have_http_status(:forbidden)
    end

    it 'refuses a token with no subject' do
      fake.claims = { sub: nil }

      expect_refused
    end

    it 'refuses a token with no email' do
      fake.claims = { email: nil }

      expect_refused
    end

    it 'accepts a signature algorithm only from the allow-list' do
      with_env('OIDC_ID_TOKEN_ALGS' => 'ES384 RS256') { expect_refused }
    end
  end

  describe 'who the person is' do
    it 'finds the user by (issuer, sub), whatever address the provider now reports' do
      user = sign_in_user
      delete '/auth/oidc/logout'

      fake.claims = { email: 'ada.new@example.com' }
      oidc_sign_in

      expect(response).to redirect_to('/')
      expect(User.count).to eq(1)
      expect(user.reload.email).to eq('ada.new@example.com')
    end

    it 'refuses a different person who arrives with an address a user already holds (recycled email)' do
      owner = sign_in_user
      delete '/auth/oidc/logout'

      fake.subject = SecureRandom.uuid
      oidc_sign_in

      expect(response).to have_http_status(:conflict)
      expect(OidcSession.where(user: owner).count).to eq(1)
      expect(User.count).to eq(1)
      get '/settings/profile'
      expect(response).to redirect_to(%r{/auth/oidc/start})
    end

    it 'gives a recycled address its own account once the old person has moved on' do
      old_user = sign_in_user
      delete '/auth/oidc/logout'
      fake.claims = { email: 'moved@example.com' }
      oidc_sign_in
      delete '/auth/oidc/logout'

      fake.subject = SecureRandom.uuid
      fake.claims = {}
      oidc_sign_in

      new_user = User.find_by!(sso_subject: fake.subject)
      expect(new_user.email).to eq('ada@example.com')
      expect(new_user.account_id).not_to eq(old_user.account_id)
      expect(old_user.reload.email).to eq('moved@example.com')
    end

    it 'never links an unbound user by email: only an invitation is matched by address' do
      create(:user, email: 'ada@example.com')

      oidc_sign_in

      expect(response).to have_http_status(:conflict)
      expect(User.find_by(email: 'ada@example.com').sso_subject).to be_nil
    end

    it 'joins the inviting account on a verified invited address, once' do
      inviter = create(:user)
      AccountInvitation.invite!(account: inviter.account, email: 'ada@example.com', role: 'viewer')

      oidc_sign_in

      user = User.find_by!(sso_subject: fake.subject)
      expect(user).to have_attributes(account_id: inviter.account_id, role: 'viewer')
      expect(AccountInvitation.pending).to be_empty
    end

    it 'does not join on an address that is not verified' do
      inviter = create(:user)
      AccountInvitation.invite!(account: inviter.account, email: 'ada@example.com', role: 'viewer')
      fake.claims = { email_verified: false }

      oidc_sign_in

      expect(AccountInvitation.pending.count).to eq(1)
      expect(User.where(account_id: inviter.account_id).count).to eq(1)
    end

    it 'creates no account when sign-up is closed' do
      with_env('OIDC_ALLOW_SIGNUP' => 'false') { oidc_sign_in }

      expect(response).to have_http_status(:forbidden)
      expect(User.count).to eq(0)
    end

    it 'still lets an invited person in when sign-up is closed' do
      inviter = create(:user)
      AccountInvitation.invite!(account: inviter.account, email: 'ada@example.com', role: 'editor')

      with_env('OIDC_ALLOW_SIGNUP' => 'false') { oidc_sign_in }

      expect(response).to redirect_to('/')
    end
  end

  describe 'the session registry' do
    it 'ends a session whose row is revoked' do
      user = sign_in_user
      user.oidc_sessions.sole.revoke!

      get '/settings/profile'

      expect(response).to redirect_to(%r{/auth/oidc/start})
    end

    it 'ends a session past the maximum age' do
      user = sign_in_user
      user.oidc_sessions.sole.update!(expires_at: 1.minute.ago)

      get '/settings/profile'

      expect(response).to redirect_to(%r{/auth/oidc/start})
    end

    it 'stamps the session with the configured lifetime' do
      with_env('OIDC_SESSION_MAX_AGE_SECONDS' => '600') { sign_in_user }

      expect(OidcSession.sole.expires_at).to be_within(5.seconds).of(10.minutes.from_now)
    end

    it 'ignores a token that does not belong to the signed-in user' do
      first = sign_in_user
      delete '/auth/oidc/logout'
      fake.subject = SecureRandom.uuid
      fake.claims = { email: 'grace@example.com' }
      second = sign_in_user

      expect(first.oidc_sessions.sole.revoked_at).to be_present
      expect(second.oidc_sessions.active.count).to eq(1)
    end
  end

  describe 'sign-out (RP-initiated logout)' do
    it 'revokes the row and sends the browser to end_session with id_token_hint, post_logout_redirect_uri and state' do
      user = sign_in_user

      delete '/auth/oidc/logout'

      expect(user.oidc_sessions.sole.revoked_at).to be_present
      uri = URI.parse(response.location)
      expect("#{uri.scheme}://#{uri.host}#{uri.path}").to eq("#{issuer}/oauth2/logout-all")
      query = Rack::Utils.parse_query(uri.query)
      expect(query['id_token_hint'].split('.').size).to eq(3)
      expect(query).to include('post_logout_redirect_uri' => FakeOidcProvider::POST_LOGOUT_REDIRECT_URI,
                               'client_id' => 'sign-app')
      expect(query['state'].length).to be >= 16
    end

    it 'leaves the person signed out' do
      sign_in_user
      delete '/auth/oidc/logout'

      get '/settings/profile'

      expect(response).to redirect_to(%r{/auth/oidc/start})
    end
  end

  describe 'back-channel logout' do
    let!(:user) { sign_in_user }

    def post_logout(token)
      post '/auth/oidc/backchannel-logout', params: { logout_token: token }
    end

    it 'revokes the sessions of the provider session and answers 200 with no-store' do
      post_logout(fake.logout_token)

      expect(response).to have_http_status(:ok)
      expect(response.headers['Cache-Control']).to include('no-store')
      expect(user.oidc_sessions.sole.revoked_at).to be_present
      get '/settings/profile'
      expect(response).to redirect_to(%r{/auth/oidc/start})
    end

    it 'needs no session and no CSRF token' do
      reset!

      post_logout(fake.logout_token)

      expect(response).to have_http_status(:ok)
    end

    it 'revokes every session of the person when only sub is named' do
      post_logout(fake.logout_token(sid: nil))

      expect(user.oidc_sessions.active).to be_empty
    end

    it 'leaves other provider sessions alone' do
      post_logout(fake.logout_token(sid: 'another-sid', sub: nil))

      expect(response).to have_http_status(:ok)
      expect(user.oidc_sessions.active.count).to eq(1)
    end

    it 'records the jti once, in the database, and refuses a replay with 400' do
      token = fake.logout_token

      post_logout(token)
      expect(OidcLogoutToken.where(issuer:).count).to eq(1)

      post_logout(token)
      expect(response).to have_http_status(:bad_request)
      expect(response.headers['Cache-Control']).to include('no-store')
      expect(OidcLogoutToken.count).to eq(1)
    end

    it 'does not use up the jti of a token that was refused' do
      jti = SecureRandom.uuid

      post_logout(fake.logout_token({ jti:, aud: 'another-client' }))
      expect(response).to have_http_status(:bad_request)
      expect(OidcLogoutToken.where(jti:)).to be_empty

      post_logout(fake.logout_token({ jti: }))
      expect(response).to have_http_status(:ok)
    end

    {
      'a wrong issuer' => { iss: 'https://evil.example.net' },
      'a wrong audience' => { aud: 'another-client' },
      'an expired token' => { exp: 1.minute.ago.to_i, iat: 5.minutes.ago.to_i },
      'a token from the future' => { iat: 1.hour.from_now.to_i, exp: 2.hours.from_now.to_i },
      'a nonce (an id_token is not a logout token)' => { nonce: 'abc' },
      'no events claim' => { events: nil },
      'the wrong event' => { events: { 'http://example.com/event' => {} } },
      'no jti' => { jti: nil },
      'neither sub nor sid' => { sub: nil, sid: nil }
    }.each do |name, overrides|
      it "answers 400 for #{name} and revokes nothing" do
        post_logout(fake.logout_token(overrides))

        expect(response).to have_http_status(:bad_request)
        expect(user.oidc_sessions.active.count).to eq(1)
      end
    end

    it 'answers 400 for a token typed JWT instead of logout+jwt' do
      post_logout(fake.logout_token({}, header: { typ: 'JWT' }))

      expect(response).to have_http_status(:bad_request)
    end

    it 'answers 400 for a signature made with another key' do
      fake.use_foreign_key!

      post_logout(fake.logout_token)

      expect(response).to have_http_status(:bad_request)
      expect(user.oidc_sessions.active.count).to eq(1)
    end

    it 'answers 400 for alg none and for garbage' do
      none = "#{Base64.urlsafe_encode64({ alg: 'none', typ: 'logout+jwt' }.to_json, padding: false)}." \
             "#{Base64.urlsafe_encode64({ iss: issuer, aud: 'sign-app' }.to_json, padding: false)}."

      post_logout(none)
      expect(response).to have_http_status(:bad_request)

      post_logout('not-a-jwt')
      expect(response).to have_http_status(:bad_request)

      post '/auth/oidc/backchannel-logout'
      expect(response).to have_http_status(:bad_request)
    end

    it 'answers 400 for an HS256 token signed with the public key' do
      fake.alg = 'HS256'
      token = JWT.encode({ iss: issuer, aud: 'sign-app', iat: Time.now.to_i, exp: 2.minutes.from_now.to_i, jti: 'x', sid: 'sid-1',
                           events: { FakeOidcProvider::EVENT => {} } }, fake.key.public_to_pem, 'HS256',
                         { kid: FakeOidcProvider::KID, typ: 'logout+jwt' })

      post_logout(token)

      expect(response).to have_http_status(:bad_request)
      expect(user.oidc_sessions.active.count).to eq(1)
    end

    it 'is not drawn when external sign-in is off' do
      with_routes_for('AUTH_MODE' => nil) do
        expect { post '/auth/oidc/backchannel-logout', params: { logout_token: 'x' } }
          .to raise_error(ActionController::RoutingError)
      end
    end
  end

  describe 'step-up for a sensitive action' do
    let(:step_env) do
      { 'OIDC_STEP_UP_ACR' => 'urn:example:acr:2', 'OIDC_STEP_UP_ACR_ORDER' => 'urn:example:acr:1,urn:example:acr:2,urn:example:acr:3',
        'OIDC_STEP_UP_ACTIONS' => 'webhooks,api_token' }
    end

    def start_step_up(action = 'webhooks', return_to: '/settings/webhooks')
      get '/auth/oidc/step_up', params: { action_name: action, return_to: }
      fake.authorize(response.location).then { |url| URI.parse(url).request_uri }
    end

    before { sign_in_user }

    it 'does nothing for an action that is not listed' do
      with_env(step_env.merge('OIDC_STEP_UP_ACTIONS' => 'api_token')) do
        post '/settings/webhooks', params: { webhook_url: { url: 'https://hooks.example.com/x' } }

        expect(response).not_to redirect_to(%r{/auth/oidc/step_up})
      end
    end

    it 'sends a protected action through the provider with acr_values, max_age=0 and an action-bound nonce' do
      with_env(step_env) do
        post '/settings/webhooks', params: { webhook_url: { url: 'https://hooks.example.com/x' } }
        expect(response).to redirect_to(%r{/auth/oidc/step_up\?action_name=webhooks})

        callback = start_step_up
        params = fake.authorizations.last
        expect(params).to include('acr_values' => 'urn:example:acr:2', 'max_age' => '0')
        expect(params['nonce']).to match(/\A\h{64}\z/) # an HMAC, not a random value
        expect(params['prompt']).to be_nil

        get callback
        expect(response).to redirect_to('/settings/webhooks')
      end
    end

    it 'lets the action through once after a good proof, and asks again the next time' do
      with_env(step_env) do
        get start_step_up
        expect(response).to redirect_to('/settings/webhooks')

        expect { post '/settings/webhooks', params: { webhook_url: { url: 'https://hooks.example.com/x' } } }
          .to change(WebhookUrl, :count).by(1)

        post '/settings/webhooks', params: { webhook_url: { url: 'https://hooks.example.com/y' } }
        expect(response).to redirect_to(%r{/auth/oidc/step_up})
        expect(WebhookUrl.count).to eq(1)
      end
    end

    it 'does not let a proof for one action unlock another' do
      with_env(step_env) do
        get start_step_up('api_token', return_to: '/settings/api')

        post '/settings/webhooks', params: { webhook_url: { url: 'https://hooks.example.com/x' } }

        expect(response).to redirect_to(%r{/auth/oidc/step_up\?action_name=webhooks})
        expect(WebhookUrl.count).to eq(0)
      end
    end

    it 'accepts a stronger acr' do
      with_env(step_env) do
        fake.claims = { acr: 'urn:example:acr:3' }

        get start_step_up

        expect(response).to redirect_to('/settings/webhooks')
      end
    end

    it 'refuses an acr below the required one' do
      with_env(step_env) do
        fake.claims = { acr: 'urn:example:acr:1' }

        get start_step_up

        expect(response).to have_http_status(:forbidden)
        expect(response.body).to include('step up acr too low')
      end
    end

    it 'refuses a result that was not a fresh authentication (auth_time before the request)' do
      with_env(step_env) do
        fake.claims = { auth_time: 10.minutes.ago.to_i }

        get start_step_up

        expect(response).to have_http_status(:bad_request)
        expect(response.body).to include('authentication not fresh')
      end
    end

    it 'refuses a nonce that is not the action\'s' do
      with_env(step_env) do
        fake.claims = { nonce: 'f' * 64 }

        get start_step_up

        expect(response).to have_http_status(:bad_request)
      end
    end

    it 'refuses an answer for another person' do
      with_env(step_env) do
        fake.claims = { sub: SecureRandom.uuid }

        get start_step_up

        expect(response).to have_http_status(:unauthorized)
        post '/settings/webhooks', params: { webhook_url: { url: 'https://hooks.example.com/x' } }
        expect(WebhookUrl.count).to eq(0)
      end
    end

    it 'does not start for an action that is not configured' do
      with_env(step_env) do
        get '/auth/oidc/step_up', params: { action_name: 'account_deletion' }

        expect(response).to have_http_status(:not_found)
      end
    end

    it 'does not start without a session' do
      delete '/auth/oidc/logout'

      with_env(step_env) do
        get '/auth/oidc/step_up', params: { action_name: 'webhooks' }

        expect(response).to redirect_to(%r{/auth/oidc/start})
      end
    end
  end

  describe 'the configuration' do
    it 'answers 404 when OIDC is not configured' do
      with_env('OIDC_ISSUER' => nil) do
        get '/auth/oidc/start'

        expect(response).to have_http_status(:not_found)
      end
    end

    it 'shows a plain error when the provider cannot be reached' do
      stub_request(:get, "#{issuer}/.well-known/openid-configuration").to_timeout

      get '/auth/oidc/start'

      expect(response).to have_http_status(:service_unavailable)
    end

    it 'refuses discovery that names another issuer' do
      allow(fake).to(receive(:discovery_document).and_wrap_original { |m| m.call.merge(issuer: 'https://evil.example.net') })

      get '/auth/oidc/start'

      expect(response).to have_http_status(:service_unavailable)
    end
  end
end
