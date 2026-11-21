# frozen_string_literal: true

require 'rails_helper'

# AUTH_MODE=external: there is no local sign-in. The routes are not drawn (not
# redirected) and people come in only through the JWT handoff, which provisions a
# new account on first sign-in.
describe 'External authentication' do
  def routed_controllers
    Rails.application.routes.routes.map { |route| route.defaults[:controller].to_s }.uniq
  end

  def routable?(verb, path)
    Rails.application.routes.recognize_path(path, method: verb)
    true
  rescue ActionController::RoutingError
    false
  end

  describe 'stock mode' do
    it 'draws the local sign-in, password, invitation, setup and two-factor routes' do
      expect(routed_controllers).to include('sessions', 'passwords', 'invitations', 'setup', 'mfa_setup',
                                            'users_send_reset_password')
      expect(routable?(:post, '/sign_in')).to be(true)
      expect(routable?(:get, '/setup')).to be(true)
    end
  end

  describe 'with AUTH_MODE=external' do
    around do |example|
      with_routes_for('AUTH_MODE' => 'external') { example.run }
    end

    it 'does not draw any local auth route' do
      expect(routed_controllers & Extensions::HostedBoot::LOCAL_AUTH_CONTROLLERS).to be_empty
      expect(Extensions::HostedBoot.local_auth_routes(Rails.application.routes.routes)).to be_empty
    end

    it 'answers 404 for login, password, reset, invitation, setup and two-factor paths' do
      expect(routable?(:post, '/sign_in')).to be(false)
      expect(routable?(:get, '/sign_in')).to be(false)
      expect(routable?(:delete, '/sign_out')).to be(false)
      expect(routable?(:post, '/password')).to be(false)
      expect(routable?(:put, '/password')).to be(false)
      expect(routable?(:get, '/password/new')).to be(false)
      expect(routable?(:get, '/invitation')).to be(false)
      expect(routable?(:put, '/invitation')).to be(false)
      expect(routable?(:get, '/setup')).to be(false)
      expect(routable?(:post, '/setup')).to be(false)
      expect(routable?(:get, '/mfa_setup')).to be(false)
      expect(routable?(:put, '/users/1/send_reset_password')).to be(false)
      expect(routable?(:patch, '/settings/profile/update_password')).to be(false)
      expect(routable?(:post, '/users')).to be(false)
    end

    it 'keeps the handoff, the sign-in start and sign-out' do
      expect(routable?(:get, '/sso/start')).to be(true)
      expect(routable?(:post, '/sso/handoff')).to be(true)
      expect(routable?(:delete, '/sso/sign_out')).to be(true)
    end

    it 'sends a signed-out visitor to the handoff start, not to a local login page' do
      create(:user)

      get '/settings/profile'

      expect(response).to redirect_to('/sso/start')
    end

    it 'does not redirect an empty install to a setup wizard' do
      get '/'

      expect(response).not_to redirect_to('/setup')
    end

    it 'has no endpoint that takes a password: the request finds no route' do
      expect { post '/sign_in', params: { user: { email: 'a@example.test', password: 'secret' } } }
        .to raise_error(ActionController::RoutingError)
    end

    context 'with a configured identity provider' do
      let(:auth) { Fakes::AuthProvider.new(email: 'first.signin@example.test') }

      before { Extensions.register(:auth, auth) }

      def start_flow
        with_env('JWT_SSO_LOGIN_URL' => 'https://idp.example.test/login') do
          get '/sso/start'
          Rack::Utils.parse_query(URI.parse(response.location).query)['state']
        end
      end

      it 'provisions an account on first sign-in and signs the person in' do
        expect(User.count).to eq(0)
        state = start_flow

        post '/sso/handoff', params: { token: "token-for-#{state}", state: }

        expect(response).to redirect_to('/')
        expect(User.where(email: 'first.signin@example.test').count).to eq(1)
        expect(Account.count).to eq(1)

        get '/'

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('Sign out')
      end

      it 'signs the same person into the same account the second time' do
        2.times do
          state = start_flow
          post '/sso/handoff', params: { token: "token-for-#{state}", state: }
          delete '/sso/sign_out'
        end

        expect(User.count).to eq(1)
        expect(Account.count).to eq(1)
      end

      it 'signs out through the handoff controller' do
        state = start_flow
        post '/sso/handoff', params: { token: "token-for-#{state}", state: }

        delete '/sso/sign_out'
        get '/settings/profile'

        expect(response).to redirect_to('/sso/start')
      end

      it 'shows a retry page, not a redirect loop, when the handoff fails' do
        start_flow

        post '/sso/handoff', params: { token: 'forged', state: 'nope' }

        expect(response).to have_http_status(:unauthorized)
        expect(response.body).to include('Sign-in failed')
        expect(response.body).to include('/sso/start')
      end
    end

    it 'shows no local password or two-factor settings to a signed-in person' do
      user = create(:user)
      sign_in(user)

      get settings_profile_index_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('update_password')
      expect(response.body).not_to include('mfa_setup')
    end
  end
end
