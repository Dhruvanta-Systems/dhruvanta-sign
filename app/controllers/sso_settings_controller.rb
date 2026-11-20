# frozen_string_literal: true

class SsoSettingsController < ApplicationController
  # Answer 403 (not the app-wide redirect) so a denied change is unmistakable.
  rescue_from CanCan::AccessDenied do
    head :forbidden
  end

  before_action :load_encrypted_config
  authorize_resource :encrypted_config

  def index; end

  def create
    @encrypted_config.assign_attributes(value: params.dig(:encrypted_config, :value)&.to_unsafe_h)
    @encrypted_config.save!
    redirect_to settings_sso_index_path, notice: I18n.t('settings_have_been_saved')
  end

  private

  def load_encrypted_config
    @encrypted_config =
      EncryptedConfig.find_or_initialize_by(account: current_account, key: 'saml_configs')
  end
end
