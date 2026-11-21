# frozen_string_literal: true

require 'rails_helper'

# AUTH_MODE=external: there is no local sign-in. The routes are not drawn (not
# redirected) and people come in only through the OpenID Connect provider, which
# provisions an account on first sign-in (see spec/requests/oidc_login_spec.rb for the
# protocol itself).
describe 'External authentication', :oidc do
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

    it 'draws no OpenID Connect route' do
      expect(routed_controllers).not_to include('oidc')
    end
  end

  describe 'with AUTH_MODE=external' do
    around do |example|
      with_routes_for(oidc_env('AUTH_MODE' => 'external')) { example.run }
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

    it 'draws the OpenID Connect routes and none of the removed custom handoff' do
      expect(routable?(:get, '/auth/oidc/start')).to be(true)
      expect(routable?(:get, '/auth/oidc/callback')).to be(true)
      expect(routable?(:post, '/auth/oidc/backchannel-logout')).to be(true)
      expect(routable?(:delete, '/auth/oidc/logout')).to be(true)
      expect(routable?(:get, '/sso/start')).to be(false)
      expect(routable?(:post, '/sso/handoff')).to be(false)
      expect(routable?(:post, '/api/auth/sso-handoff')).to be(false)
      expect(routed_controllers).not_to include('jwt_sso_handoff')
    end

    it 'sends a signed-out visitor to the provider flow, not to a local login page' do
      create(:user)

      get '/settings/profile'

      expect(response).to redirect_to('/auth/oidc/start')
    end

    it 'does not redirect an empty install to a setup wizard' do
      get '/'

      expect(response).not_to redirect_to('/setup')
    end

    it 'has no endpoint that takes a password: the request finds no route' do
      expect { post '/sign_in', params: { user: { email: 'a@example.test', password: 'secret' } } }
        .to raise_error(ActionController::RoutingError)
    end

    it 'provisions an account on first sign-in and signs the person in' do
      expect(User.count).to eq(0)

      oidc_sign_in

      expect(response).to redirect_to('/')
      expect(Account.count).to eq(1)

      get '/'
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Sign out')
    end

    it 'shows no local password or two-factor settings to a signed-in person' do
      oidc_sign_in

      get settings_profile_index_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('update_password')
      expect(response.body).not_to include('mfa_setup')
    end
  end
end
