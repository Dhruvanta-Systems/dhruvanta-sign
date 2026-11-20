# frozen_string_literal: true

module Outbound
  # Post-create emit hook for the `submission_created` outbox event.
  #
  # The emit is attached to the model lifecycle (`Submission#after_commit on:
  # :create`) rather than to each controller, so every way of creating a
  # submission (API, HTML invite, bulk send, embedded start form, MCP, resubmit)
  # emits the event and a future creation path cannot forget to.
  #
  # Idempotent: the key is `submission:<id>:created` and the UNIQUE index on
  # `webhook_outbox.delivery_id` keeps a single row per submission even if the
  # emit fires twice.
  #
  # Failure-additive: nothing raises out of the `after_commit` callback, because
  # that would abort the surrounding transaction finalisation.
  module SubmissionWebhookEmitter
    module_function

    # Called from `Submission#after_commit on: :create`. Emits exactly
    # one `submission_created` outbox row keyed on `submission.id`.
    # Returns the delivery_id on enqueue (or duplicate-suppress); nil
    # on internal failure.
    def emit(submission)
      return nil if submission.nil?
      return nil unless submission.persisted?

      payload = build_payload(submission)

      Outbound::WebhooksDispatcher.enqueue_submission_created(submission, payload)
    rescue StandardError => e
      # Never raise out of an after_commit — webhook emit is best-
      # effort observability, not a correctness predicate of the
      # signing flow (mirrors the same posture documented on
      # `Outbound::WebhooksDispatcher.enqueue`).
      Rails.logger.warn(
        '[outbound-webhook-emit] submission_created failed ' \
        "submission_id=#{submission&.id} reason=#{e.class.name}: #{e.message}"
      )
      nil
    end

    # ----- internals -----

    def build_payload(submission)
      {
        'event_type' => WebhookOutbox::EVENT_SUBMISSION_CREATED,
        'submission_id' => submission.id,
        'account_id' => submission.account_id,
        'template_id' => submission.template_id,
        'created_at' => submission.created_at&.utc&.iso8601,
        # `source` is the existing Submission enum
        # (invite/bulk/api/embed/link) — gives per-callsite identity
        # without wiring N callbacks.
        'source' => submission.source.to_s,
        'submitter_count' => submission.submitters.size
      }.merge(Outbound::ExternalScope.for_submission(submission))
    end
  end
end
