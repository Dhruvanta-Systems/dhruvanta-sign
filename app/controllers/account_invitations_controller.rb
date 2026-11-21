# frozen_string_literal: true

# Teammate invitations for AUTH_MODE=external (see AccountInvitation). Drawn only in
# that mode; an admin of the account invites an email with a role.
class AccountInvitationsController < ApplicationController
  before_action { authorize!(:create, User.new(account_id: current_account.id)) }

  def new
    @invitation = current_account.account_invitations.new(role: User::EDITOR_ROLE)

    render layout: turbo_native_app? ? 'plain' : true
  end

  def create
    # Refuse early when the plan has no room for another member.
    Extensions::Gate.check_resource!(current_account, :users)

    invitation = AccountInvitation.invite!(account: current_account, invited_by: current_user,
                                           email: invitation_params[:email], role: invited_role)

    UserMailer.account_invitation_email(invitation).deliver_later!

    redirect_back fallback_location: settings_users_path, notice: 'Invitation sent.'
  rescue ActiveRecord::RecordInvalid => e
    redirect_back fallback_location: settings_users_path, alert: e.record.errors.full_messages.to_sentence
  end

  def destroy
    current_account.account_invitations.pending.find(params[:id]).destroy!

    redirect_back fallback_location: settings_users_path, notice: 'Invitation removed.'
  end

  private

  def invitation_params
    params.require(:account_invitation).permit(:email)
  end

  # Not mass-assigned: only a known account role is passed on (anything else is
  # refused by the model's validation).
  def invited_role
    role = params.dig(:account_invitation, :role).to_s

    AccountInvitation::ROLES.include?(role) ? role : nil
  end
end
