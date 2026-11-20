# frozen_string_literal: true

class SmsSettingsController < ApplicationController
  before_action :load_encrypted_config
  authorize_resource :encrypted_config, only: :index
  authorize_resource :encrypted_config, parent: false, except: :index

  def index; end

  # Credential fields are write-only: they are never rendered back into the form,
  # and a blank submission keeps the value already saved.
  SECRET_FIELDS = %w[account_sid auth_token api_key].freeze

  def create
    submitted = params.dig(:encrypted_config, :value)&.to_unsafe_h || {}
    stored = @encrypted_config.value.is_a?(Hash) ? @encrypted_config.value : {}
    SECRET_FIELDS.each do |field|
      submitted[field] = stored[field] if submitted[field].blank? && stored[field].present?
    end
    @encrypted_config.assign_attributes(value: submitted)

    if params[:remove] == '1' || @encrypted_config.value.values.all?(&:blank?)
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
