# frozen_string_literal: true

require 'rails_helper'

# A Rails session outlives the identity provider's own (a disabled person is not
# signed out here), so with external sign-in a session is bounded and the person is
# sent through the handoff again when it lapses.
describe 'SSO session lifetime' do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user) }

  around { |example| with_routes_for('AUTH_MODE' => 'external') { example.run } }

  it 'keeps a fresh session' do
    sign_in(user)

    get settings_profile_index_path

    expect(response).to have_http_status(:ok)
  end

  it 'sends the person through the handoff again when the session is older than the maximum age' do
    sign_in(user)
    get settings_profile_index_path
    expect(response).to have_http_status(:ok)

    travel_to(13.hours.from_now) do
      get settings_profile_index_path

      expect(response).to redirect_to('/sso/start')

      get settings_profile_index_path
      expect(response).to redirect_to('/sso/start') # and is really signed out
    end
  end

  it 'reads the maximum age from SSO_SESSION_MAX_AGE_SECONDS' do
    with_env('SSO_SESSION_MAX_AGE_SECONDS' => '600') do
      sign_in(user)
      get settings_profile_index_path
      expect(response).to have_http_status(:ok)

      travel_to(11.minutes.from_now) do
        get settings_profile_index_path

        expect(response).to redirect_to('/sso/start')
      end
    end
  end

  it 'does not apply outside external sign-in' do
    with_routes_for('AUTH_MODE' => nil) do
      sign_in(user)

      travel_to(48.hours.from_now) do
        get settings_profile_index_path

        expect(response).to have_http_status(:ok)
      end
    end
  end

  it 'still lets a lapsed person sign out' do
    sign_in(user)

    travel_to(13.hours.from_now) do
      delete '/sso/sign_out'

      expect(response).to redirect_to('/')
    end
  end
end
