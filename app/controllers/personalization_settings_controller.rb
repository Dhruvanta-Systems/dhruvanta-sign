# frozen_string_literal: true

class PersonalizationSettingsController < ApplicationController
  ALLOWED_KEYS = [
    AccountConfig::FORM_COMPLETED_BUTTON_KEY,
    AccountConfig::SUBMITTER_INVITATION_EMAIL_KEY,
    AccountConfig::SUBMITTER_INVITATION_REMINDER_EMAIL_KEY,
    AccountConfig::SUBMITTER_DOCUMENTS_COPY_EMAIL_KEY,
    AccountConfig::SUBMITTER_COMPLETED_EMAIL_KEY,
    AccountConfig::FORM_COMPLETED_MESSAGE_KEY,
    *(Docuseal.multitenant? ? [] : [AccountConfig::POLICY_LINKS_KEY])
  ].freeze

  InvalidKey = Class.new(StandardError)

  before_action :load_and_authorize_account_config, only: :create, unless: :logo_request?

  def show
    authorize!(:read, AccountConfig)

    return unless request.format.to_sym == :turbo_stream

    redirect_to settings_personalization_path(format: :html), status: :see_other
  end

  def create
    if params[:logo].present?
      authorize!(:update, current_account)

      if params[:logo].size > 2.megabytes
        return redirect_back(fallback_location: settings_personalization_path,
                             alert: 'File is too large. Maximum size is 2MB.', status: :see_other)
      end
      unless params[:logo].content_type.in?(%w[image/png image/jpeg image/svg+xml])
        return redirect_back(fallback_location: settings_personalization_path,
                             alert: 'Invalid file type. Only PNG, JPG, and SVG are supported.', status: :see_other)
      end
      current_account.logo.attach(params[:logo])
      return redirect_back(fallback_location: settings_personalization_path,
                           notice: I18n.t('settings_have_been_saved'), status: :see_other)
    end

    if params[:remove_logo] == 'true'
      authorize!(:update, current_account)

      current_account.logo.purge
      return redirect_back(fallback_location: settings_personalization_path,
                           notice: I18n.t('settings_have_been_saved'), status: :see_other)
    end

    if @account_config.value.is_a?(Hash)
      @account_config.value = @account_config.value.reject do |_, v|
        v.blank? && v != false
      end
    end

    if @account_config.value != false && @account_config.value.blank?
      @account_config.destroy!
    else
      @account_config.save!
    end

    redirect_back(fallback_location: settings_personalization_path,
                  notice: I18n.t('settings_have_been_saved'), status: :see_other)
  end

  private

  def load_and_authorize_account_config
    @account_config =
      current_account.account_configs.find_or_initialize_by(key: account_config_params[:key])

    @account_config.assign_attributes(account_config_params)

    authorize!(:create, @account_config)

    raise InvalidKey unless ALLOWED_KEYS.include?(@account_config.key)

    @account_config
  end

  def account_config_params
    attrs = params.require(:account_config).permit(:key, :value, { value: {} }, { value: [] })

    return attrs if attrs[:value].is_a?(String)

    attrs[:value]&.transform_values! do |value|
      if value.in?(%w[true false])
        value == 'true'
      else
        value
      end
    end

    attrs
  end

  def logo_request?
    params[:logo].present? || params[:remove_logo] == 'true'
  end
end
