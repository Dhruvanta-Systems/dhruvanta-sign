# frozen_string_literal: true

class SubmitFormVideoKycController < ApplicationController
  skip_before_action :authenticate_user!
  skip_authorization_check
  skip_forgery_protection

  def show
    submitter = Submitter.find_by!(slug: params[:submit_form_slug] || params[:slug])
    return render_closed unless Submitters::FormState.open_for_signing?(submitter, current_user, request)

    result = Extensions.verification.status(submitter.slug)

    render json: result.presence || { status: 'not_started' }
  end

  def create
    submitter = Submitter.find_by!(slug: params[:submit_form_slug] || params[:slug])
    return render_closed unless Submitters::FormState.open_for_signing?(submitter, current_user, request)

    config = EncryptedConfig.find_by(account: submitter.account, key: 'video_kyc_configs')&.value

    return render json: { error: 'Video KYC not configured' }, status: :unprocessable_content if config.blank?
    unless Extensions.feature?(submitter.account, 'video_kyc')
      return render json: { error: 'Video KYC requires an active premium plan' },
                    status: :payment_required
    end

    result = Extensions.verification.start(
      account_id: submitter.account_id,
      submitter_slug: submitter.slug,
      name: submitter.name,
      email: submitter.email,
      config:
    )

    return render json: { error: 'Video KYC service unavailable' }, status: :unprocessable_content if result.blank?

    return render json: result, status: :unprocessable_content if result['error'].present?

    SubmissionEvent.create!(
      submitter:,
      submission: submitter.submission,
      event_type: 'video_kyc_started',
      data: result
    )

    render json: result
  end

  private

  def render_closed
    render json: { error: I18n.t('form_has_been_archived') }, status: :unprocessable_content
  end
end
