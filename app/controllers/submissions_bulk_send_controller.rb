# frozen_string_literal: true

class SubmissionsBulkSendController < ApplicationController
  before_action :load_template
  before_action -> { require_premium_feature!('bulk_send') }

  def new
    authorize!(:create, Submission)
  end

  def create
    authorize!(:create, Submission)
    file = params[:file]
    return redirect_back(fallback_location: template_path(@template), alert: 'Please upload a file.') if file.blank?
    if file.size > 5.megabytes
      return redirect_back(fallback_location: template_path(@template),
                           alert: 'File too large. Max 5MB.')
    end

    result = Submissions::CreateFromSpreadsheet.call(template: @template, user: current_user, file:, params:)
    Submissions.send_signature_requests(result[:submissions]) if params[:send_email] != 'false'
    notice = "#{result[:submissions].size} submissions created."
    notice += " #{result[:errors].size} rows skipped." if result[:errors].any?
    redirect_to template_path(@template), notice:
  end

  private

  def load_template
    @template = current_account.templates.find(params[:template_id])
  end
end
