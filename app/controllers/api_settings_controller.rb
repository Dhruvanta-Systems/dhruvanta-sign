# frozen_string_literal: true

class ApiSettingsController < ApplicationController
  require_step_up :api_token, only: :create

  def index
    authorize!(:read, current_user.access_token)
  end

  def create
    authorize!(:manage, current_user.access_token)

    current_user.access_token.token = SecureRandom.base58(AccessToken::TOKEN_LENGTH)

    current_user.access_token.save!

    redirect_back(fallback_location: settings_api_index_path, notice: I18n.t('api_token_has_been_updated'))
  end
end
