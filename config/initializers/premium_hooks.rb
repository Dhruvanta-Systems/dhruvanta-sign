# frozen_string_literal: true

# Register hooks that notify the premium service about DocuSeal events.
# If PREMIUM_SERVICE_URL is not set, these hooks do nothing.
Rails.application.config.after_initialize do
  next unless PremiumBridge.enabled?

  # After a submitter completes signing
  ActiveSupport.on_load(:after_submitter_completion) do |submitter|
    PremiumBridge.notify('form.completed', {
                           account_id: submitter.account_id,
                           submitter_id: submitter.id,
                           submission_id: submitter.submission_id,
                           email: submitter.email,
                           phone: submitter.phone,
                           document_hash: submitter.documents.first&.metadata&.dig('sha256')
                         })
  end

  # After a submission is fully completed (all submitters done)
  ActiveSupport.on_load(:after_submission_completion) do |submission|
    PremiumBridge.notify('submission.completed', {
                           account_id: submission.account_id,
                           submission_id: submission.id
                         })
  end

  # After a submitter is created (for SMS/WhatsApp invitations)
  ActiveSupport.on_load(:after_submitter_created) do |submitter|
    return unless submitter.phone.present?

    url = Rails.application.routes.url_helpers.submit_form_url(submitter.slug, **Docuseal.default_url_options)
    template_name = submitter.submission.template&.name || 'Document'

    PremiumBridge.notify('submitter.created', {
                           account_id: submitter.account_id,
                           submitter_id: submitter.id,
                           phone: submitter.phone,
                           email: submitter.email,
                           sms_body: "Sign \"#{template_name.truncate(40)}\": #{url}",
                           whatsapp_body: "You are invited to sign \"#{template_name.truncate(40)}\".\n\nSign here: #{url}"
                         })
  end
end
