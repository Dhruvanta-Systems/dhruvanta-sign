# frozen_string_literal: true

class SmsSettingsController < ApplicationController
  before_action :load_encrypted_config
  authorize_resource :encrypted_config, only: :index
  authorize_resource :encrypted_config, parent: false, except: :index

  def index; end

  def create
    @encrypted_config.assign_attributes(value: params.dig(:encrypted_config, :value)&.to_unsafe_h)
    if @encrypted_config.value.values.all?(&:blank?)
      @encrypted_config.destroy! if @encrypted_config.persisted?
    else
      @encrypted_config.save!
    end
    redirect_to settings_sms_path, notice: I18n.t('settings_have_been_saved')
  end

  private

  def load_encrypted_config
    key = params[:config_key].presence || 'sms_configs'
    key = 'sms_configs' unless key.in?(%w[sms_configs whatsapp_configs])
    @encrypted_config = EncryptedConfig.find_or_initialize_by(account: current_account, key:)
  end
end
