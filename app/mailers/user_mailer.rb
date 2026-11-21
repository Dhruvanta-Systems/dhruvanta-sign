# frozen_string_literal: true

class UserMailer < ApplicationMailer
  def invitation_email(user, invited_by: nil)
    @current_account = invited_by&.account || user.account
    @user = user
    @token = @user.send(:set_reset_password_token)

    assign_message_metadata('user_invitation', @user)

    # Routing variables for the HTTP mail API delivery method.
    # Read by `Outbound::HttpMailApiDeliveryMethod` when the
    # `MAIL_API_ENABLED` flag is on. Set always —
    # the delivery method ignores them when SMTP is in force.
    set_mail_api_template_variables(
      account_id: @current_account.id,
      user_id: invited_by&.id,
      variables: {
        'product_name' => Docuseal.product_name,
        'first_name' => @user.first_name.to_s,
        'invited_by_name' => invited_by&.full_name.to_s,
        'cta_url' => begin
          edit_user_password_url(reset_password_token: @token)
        rescue StandardError
          nil
        end
      }.compact
    )

    I18n.with_locale(@current_account.locale) do
      mail(to: @user.friendly_name,
           subject: I18n.t('you_are_invited_to_product_name', product_name: Docuseal.product_name))
    end
  end

  # Tells someone they were invited to an account used with AUTH_MODE=external. There
  # is nothing to click through: they sign in with this address and join.
  def account_invitation_email(invitation)
    @invitation = invitation
    @current_account = invitation.account

    assign_message_metadata('account_invitation', invitation)
    set_mail_api_template_variables(account_id: @current_account.id, user_id: invitation.invited_by_user_id,
                                    variables: { 'product_name' => Docuseal.product_name,
                                                 'account_name' => @current_account.name.to_s,
                                                 'role' => invitation.role,
                                                 'cta_url' => oidc_start_url })

    I18n.with_locale(@current_account.locale) do
      mail(to: invitation.email,
           subject: I18n.t('you_are_invited_to_product_name', product_name: Docuseal.product_name))
    end
  end
end
