# frozen_string_literal: true

class SubmitFormVoiceSignatureController < ApplicationController
  skip_before_action :authenticate_user!
  skip_authorization_check
  skip_forgery_protection

  def create
    submitter = Submitter.find_by!(slug: params[:submit_form_slug] || params[:slug])
    unless Submitters::FormState.open_for_signing?(submitter, current_user, request)
      return render json: { error: I18n.t('form_has_been_archived') }, status: :unprocessable_content
    end

    return head :unprocessable_content unless params[:audio].present?
    return head :unprocessable_content unless params[:audio].content_type.start_with?('audio/')
    return head :unprocessable_content if params[:audio].size > 5.megabytes

    submitter.attachments.attach(io: params[:audio], filename: "voice_signature_#{Time.current.to_i}.webm",
                                 content_type: params[:audio].content_type, metadata: { type: 'voice_signature' })
    SubmissionEvent.create!(submitter:, submission: submitter.submission, event_type: 'voice_signature',
                            data: { ip: request.remote_ip, ua: request.user_agent })
    render json: { status: 'ok' }
  end
end
