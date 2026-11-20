# frozen_string_literal: true

module Outbound
  # Sidekiq worker that drains the `webhook_outbox` table.
  #
  # It re-schedules itself with `perform_in`, so no cron gem is needed. Start it
  # once with `Outbound::WebhookOutboxDrainWorker.perform_async` (at boot or from
  # a cron line); subsequent ticks fire themselves.
  #
  # Per tick:
  #
  #   1. Read up to BATCH_SIZE pending rows, oldest first (rows never attempted
  #      before rows awaiting a retry).
  #   2. For each row open a `requires_new: true` transaction so one row's
  #      failure does not poison its siblings.
  #   3. Increment `attempts`, dispatch, and flip the row to `sent` (2xx),
  #      `pending` (transient failure, retry budget left) or `failed` (retries
  #      exhausted or a non-retryable 4xx).
  #   4. Log a structured audit line after the transaction commits; a logger
  #      failure must not roll back the status change.
  #   5. Re-schedule the next tick.
  class WebhookOutboxDrainWorker
    include Sidekiq::Job

    # Uses the same `:webhooks` Sidekiq queue as the other webhook jobs.
    sidekiq_options queue: :webhooks, retry: 0

    BATCH_SIZE = 50
    DEFAULT_POLL_INTERVAL_SECONDS = 5

    AUDIT_EMITTED = 'DOCUSEAL_WEBHOOK_EMITTED'
    AUDIT_EMIT_FAILED = 'DOCUSEAL_WEBHOOK_EMIT_FAILED'

    def perform(opts = {})
      processed = run_once
      reschedule! if opts['reschedule'] != false
      processed
    end

    # Test seam — drain one batch synchronously and return the count
    # of rows that reached a terminal state (sent OR failed). The
    # "still pending" row count is NOT included.
    def run_once
      rows = WebhookOutbox.pending
                          .order(Arel.sql('last_attempt_at ASC NULLS FIRST'), :created_at)
                          .limit(BATCH_SIZE)

      processed = 0
      rows.each do |row|
        result = process_row(row)
        next if result.nil?

        processed += 1 if result.terminal?
        emit_audit(result)
      end
      processed
    rescue StandardError => e
      Rails.logger.warn("[outbound-webhook-drain] tick-failed reason=#{e.message}")
      0
    end

    # Per-row transactional unit. Returns a {ProcessResult} struct so
    # the caller can fan out the audit emit AFTER the row's
    # transaction has committed. A nil return means the row was
    # already drained by a sibling worker (idempotent no-op).
    #
    # Rails 7.1 / 8 deprecate `return` inside `transaction` blocks
    # (Rails 8 raises). The block expression's value bubbles via
    # `next` semantics — the last expression wins.
    def process_row(row)
      ActiveRecord::Base.transaction(requires_new: true) do
        # Re-read inside the transaction so two concurrent ticks
        # cooperate via row-level lock + status check rather than
        # racing on the original snapshot.
        fresh = WebhookOutbox.lock.find_by(id: row.id)
        next nil if fresh.nil? || !fresh.pending?

        fresh.attempts += 1
        fresh.last_attempt_at = Time.current

        result = WebhooksDispatcher.dispatch(fresh)

        if result.success?
          fresh.status = WebhookOutbox::STATUS_SENT
          fresh.sent_at = Time.current
          fresh.last_error = nil
          fresh.save!
          ProcessResult.new(
            row: fresh,
            terminal: true,
            success: true,
            http_status: result.http_status,
            error: nil
          )
        else
          fresh.last_error = result.error
          non_retryable = result.error.to_s.start_with?('non-retryable:')
          exhausted = fresh.attempts >= WebhooksDispatcher::MAX_DISPATCH_ATTEMPTS
          fresh.status = WebhookOutbox::STATUS_FAILED if non_retryable || exhausted
          fresh.save!
          ProcessResult.new(
            row: fresh,
            terminal: fresh.failed?,
            success: false,
            http_status: result.http_status,
            error: result.error
          )
        end
      end
    rescue StandardError => e
      Rails.logger.warn(
        "[outbound-webhook-drain] row-execution-threw row_id=#{row.id} reason=#{e.message}"
      )
      nil
    end

    # ----- audit emit -----

    # There is no generic audit table (`submission_events` is per submission and
    # limited to the signing flow), so the outcome is logged as one structured
    # JSON line.
    def emit_audit(result)
      return unless result.terminal?

      row = result.row
      delivery_id = row.delivery_id.to_s
      target_id_hash = Digest::SHA256.hexdigest(
        "#{row.target}:#{row.event_type}:#{delivery_id}"
      )

      payload = {
        'event_code' => result.success ? AUDIT_EMITTED : AUDIT_EMIT_FAILED,
        'occurred_at' => Time.current.utc.iso8601,
        'actor_user_id' => nil,
        'actor_account_id' => nil,
        'target_id_type' => 'DOCUSEAL_WEBHOOK',
        'target_id_hash' => target_id_hash,
        'provider_ref' => delivery_id,
        'failure_reason' => result.success ? nil : result.error,
        'metadata' => {
          'eventType' => row.event_type,
          'attempts' => row.attempts,
          'httpStatus' => result.http_status
        }.compact,
        'audience' => row.target,
        'source' => 'docuseal'
      }
      Rails.logger.info("[docuseal-webhook-audit] #{JSON.generate(payload)}")
    rescue StandardError => e
      Rails.logger.warn(
        "[outbound-webhook-drain] audit-emit-failed delivery_id=#{result.row&.delivery_id} " \
        "reason=#{e.message}"
      )
    end

    def reschedule!
      interval = ENV.fetch('WEBHOOK_OUTBOX_POLL_INTERVAL_SECONDS',
                           DEFAULT_POLL_INTERVAL_SECONDS).to_i
      interval = DEFAULT_POLL_INTERVAL_SECONDS if interval <= 0
      self.class.perform_in(interval.seconds)
    end

    ProcessResult = Struct.new(:row, :terminal, :success, :http_status, :error, keyword_init: true) do
      def terminal?
        terminal
      end
    end
  end
end
