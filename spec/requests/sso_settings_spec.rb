# frozen_string_literal: true

require 'rails_helper'

# SAML/SSO settings may be changed by admins only. Authorisation must happen
# before the attributes are assigned and saved.
RSpec.describe 'SSO settings' do
  let(:account) { create(:account) }
  let(:params) { { encrypted_config: { value: { idp_sso_url: 'https://idp.example.test/sso', idp_entity_id: 'x' } } } }

  def saved_config
    EncryptedConfig.find_by(account:, key: 'saml_configs')
  end

  %w[viewer editor].each do |role|
    context "when signed in as #{role}" do
      let(:user) { create(:user, account:, role:) }

      before { sign_in(user) }

      it 'answers 403 on POST and saves nothing' do
        post settings_sso_index_path, params: params

        expect(response).to have_http_status(:forbidden)
        expect(saved_config).to be_nil
      end

      it 'does not overwrite an existing configuration' do
        EncryptedConfig.create!(account:, key: 'saml_configs', value: { 'idp_entity_id' => 'original' })

        post settings_sso_index_path, params: params

        expect(response).to have_http_status(:forbidden)
        expect(saved_config.value).to eq('idp_entity_id' => 'original')
      end

      it 'answers 403 on GET' do
        get settings_sso_index_path

        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  context 'when signed in as admin' do
    let(:user) { create(:user, account:, role: 'admin') }

    before { sign_in(user) }

    it 'saves the configuration' do
      post settings_sso_index_path, params: params

      expect(response).to redirect_to(settings_sso_index_path)
      expect(saved_config.value['idp_sso_url']).to eq('https://idp.example.test/sso')
    end
  end
end
