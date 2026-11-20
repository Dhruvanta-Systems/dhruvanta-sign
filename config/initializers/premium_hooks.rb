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
end
