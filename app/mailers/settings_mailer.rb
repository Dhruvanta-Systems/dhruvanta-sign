# frozen_string_literal: true

class SettingsMailer < ApplicationMailer
  def smtp_successful_setup(email)
    # Routing variables for the HTTP mail API delivery method.
    # Best-effort account_id resolution from the email; if the user
    # cannot be resolved the delivery method falls back to SMTP (per
    # the missing-tenant rule in `HttpMailApiDeliveryMethod`).
    user = User.find_by(email: email.to_s.downcase)
    if user
      set_mail_api_template_variables(
        account_id: user.account_id,
        user_id: user.id,
        variables: {
          'product_name' => Docuseal.product_name,
          'recipient_email' => email.to_s
        }
      )
    end

    mail(to: email, from: email, subject: 'SMTP has been configured')
  end
end
