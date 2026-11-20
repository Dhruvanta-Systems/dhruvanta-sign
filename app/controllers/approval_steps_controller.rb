# frozen_string_literal: true

class ApprovalStepsController < ApplicationController
  before_action :load_submission
  before_action :load_approval_step, only: %i[update]
  before_action -> { require_premium_feature!('approvals') }

  def index
    authorize!(:read, @submission)
    @approval_steps = @submission.approval_steps.order(:step_order).includes(:approver)
  end

  def create
    authorize!(:update, @submission)
    @submission.approval_steps.create!(account_id: current_account.id, approver_id: params[:approver_id],
                                       step_order: @submission.approval_steps.count)
    redirect_back fallback_location: submission_path(@submission), notice: 'Approval step added.'
  end

  def update
    return head :forbidden unless @approval_step.approver_id == current_user.id

    case params[:decision]
    when 'approve'
      @approval_step.approve!(comment: params[:comment])
      Submissions.send_signature_requests([@submission]) if @submission.approval_steps.pending.empty?
    when 'reject'
      @approval_step.reject!(comment: params[:comment])
    end
    redirect_back fallback_location: submission_path(@submission), notice: "Step #{params[:decision]}d."
  end

  private

  def load_submission
    @submission = current_account.submissions.find(params[:submission_id])
  end

  def load_approval_step
    @approval_step = @submission.approval_steps.find(params[:id])
  end
end
