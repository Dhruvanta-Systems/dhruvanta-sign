# frozen_string_literal: true

require 'rails_helper'

# Which settings routes exist in hosted mode: the per-account SMTP, storage and
# SMS screens configure providers that hosted mode takes from the operator.
describe 'Hosted mode routes' do
  def routable?(verb, path)
    Rails.application.routes.recognize_path(path, method: verb)
    true
  rescue ActionController::RoutingError
    false
  end

  it 'draws the per-account SMTP, storage and SMS settings in stock mode' do
    expect(routable?(:get, '/settings/email')).to be(true)
    expect(routable?(:post, '/settings/email')).to be(true)
    expect(routable?(:get, '/settings/storage')).to be(true)
    expect(routable?(:get, '/settings/sms')).to be(true)
  end

  context 'with HOSTED_MODE=true' do
    around { |example| with_routes_for('HOSTED_MODE' => 'true') { example.run } }

    it 'has no per-account SMTP settings route' do
      expect(routable?(:get, '/settings/email')).to be(false)
      expect(routable?(:post, '/settings/email')).to be(false)
      expect(routable?(:delete, '/settings/email/1')).to be(false)
      expect(Rails.application.routes.routes.map { |r| r.defaults[:controller] }).not_to include('email_smtp_settings')
    end

    it 'has no storage or SMS settings route either' do
      expect(routable?(:get, '/settings/storage')).to be(false)
      expect(routable?(:get, '/settings/sms')).to be(false)
    end

    it 'still draws the other settings' do
      expect(routable?(:get, '/settings/profile')).to be(true)
      expect(routable?(:get, '/settings/subscriptions')).to be(true)
      expect(routable?(:get, '/settings/notifications')).to be(true)
    end

    it 'renders the settings pages without links to the removed screens' do
      user = create(:user)
      sign_in(user)

      get settings_profile_index_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('/settings/email')
      expect(response.body).not_to include('/settings/sms')
      expect(response.body).not_to include('/settings/storage')
    end

    it 'lets an account send without an SMTP server of its own' do
      expect(Accounts.can_send_emails?(create(:account))).to be(true)
    end
  end
end
