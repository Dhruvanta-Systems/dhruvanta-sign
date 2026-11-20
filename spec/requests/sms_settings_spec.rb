# frozen_string_literal: true

require 'rails_helper'

# SMS and WhatsApp credentials are write-only: the settings page shows only
# whether each one is set, never the value, and a blank field keeps the saved one.
RSpec.describe 'SMS and WhatsApp settings' do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:, role: 'admin') }

  let(:sms_secrets) { { 'account_sid' => 'AC-sms-sid-1f3a9c', 'auth_token' => 'sms-token-77e1d0' } }
  let(:wa_secrets) { { 'api_key' => 'wa-key-5b2c8e', 'auth_token' => 'wa-token-a41f09' } }

  before do
    EncryptedConfig.create!(account:, key: 'sms_configs',
                            value: sms_secrets.merge('provider' => 'twilio', 'from_number' => '+15550100'))
    EncryptedConfig.create!(account:, key: 'whatsapp_configs',
                            value: wa_secrets.merge('provider' => 'twilio', 'source_number' => '+15550101'))
    sign_in(user)
  end

  def saved(key)
    EncryptedConfig.find_by(account:, key:).value
  end

  describe 'GET /settings/sms' do
    it 'never renders a stored credential, and says each one is set' do
      get settings_sms_path

      expect(response).to have_http_status(:ok)
      (sms_secrets.values + wa_secrets.values).each do |secret|
        expect(response.body).not_to include(secret)
      end
      expect(response.body.scan('data-secret-status').size).to eq(4)
      expect(response.body.scan(/data-secret-status="[a-z_]+">set</).size).to eq(4)
      expect(response.body).to include('+15550100') # non-secret fields are still shown
    end

    it 'says "not set" when nothing is saved' do
      EncryptedConfig.where(account:).destroy_all

      get settings_sms_path

      expect(response.body.scan('>not set<').size).to eq(4)
    end
  end

  describe 'POST /settings/sms' do
    it 'keeps the saved credentials when the fields are left blank' do
      post settings_sms_path,
           params: { encrypted_config: { value: { provider: 'msg91', account_sid: '', auth_token: '',
                                                  from_number: '+15550999' } } }

      expect(saved('sms_configs')).to include(sms_secrets.merge('provider' => 'msg91', 'from_number' => '+15550999'))
    end

    it 'replaces a credential when a new one is typed' do
      post settings_sms_path(config_key: 'whatsapp_configs'),
           params: { encrypted_config: { value: { provider: 'twilio', api_key: 'new-key', auth_token: '' } } }

      expect(saved('whatsapp_configs')).to include('api_key' => 'new-key', 'auth_token' => wa_secrets['auth_token'])
    end

    it 'removes the whole configuration when asked' do
      post settings_sms_path, params: { remove: '1', encrypted_config: { value: { provider: '' } } }

      expect(EncryptedConfig.find_by(account:, key: 'sms_configs')).to be_nil
    end
  end
end
