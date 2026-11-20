# frozen_string_literal: true

module Submitters
  # One definition of "this signer link can no longer be used", shared by every
  # signer-facing entry point that does not already carry its own full set of
  # checks (embed page, voice signature, video verification, signature pad), so
  # they cannot drift from the main signer page.
  module FormState
    module_function

    # @return [Symbol, nil] why the link is closed, or nil when it is still open
    def locked_reason(submitter)
      submission = submitter.submission

      return :completed if submitter.completed_at? || submission.completed_at?
      return :declined if submitter.declined_at?
      return :archived if submission.archived_at? || submission.template&.archived_at? ||
                          submitter.account.archived_at?

      :expired if submission.expired?
    end

    # Open for the submitter to act on: not closed, not a view-only party, and
    # passing the same authorization the main signer page applies.
    def open_for_signing?(submitter, current_user, request)
      locked_reason(submitter).nil? &&
        !submitter.viewer? &&
        Submitters::AuthorizedForForm.call(submitter, current_user, request, with_order: true)
    end
  end
end
