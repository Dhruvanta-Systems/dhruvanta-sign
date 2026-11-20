# frozen_string_literal: true

require 'digest'
require 'faraday'
require 'json'
require 'securerandom'

module Outbound
  # Outbound webhook outbox: enqueue and HTTP dispatch.
  #
  # `enqueue` inserts a row; `dispatch` POSTs one row to the URL in
  # WEBHOOK_OUTBOX_URL, signed with the HMAC-SHA256 key in WEBHOOK_OUTBOX_SECRET.
  # Nothing is sent while either is unset.
  #
  # Request headers:
  #
  #   * Content-Type: application/json; charset=UTF-8
  #   * X-Webhook-Signature: lowercase hex HMAC-SHA256 of the raw body
  #     (no `sha256=` prefix)
  #   * X-Webhook-Delivery-Id: UUID, stable per (target, event type, idempotency key)
  #
  # Retry policy: 3 attempts at 250ms / 1s / 4s on HTTP 429, 5xx or network
  # errors. Any other 4xx stops immediately, since the receiver has said the
  # request is bad.
  #
  # The enqueue path never raises to its caller: a failure to write the outbox
  # row must not fail the signing flow that triggered it.
  module WebhooksDispatcher
    BACKOFF_SECONDS = [0.25, 1.0, 4.0].freeze
    MAX_DISPATCH_ATTEMPTS = 3
    REQUEST_TIMEOUT_SECONDS = 10

    module_function

    # Insert a `pending` outbox row inside the originating domain
    # transaction. The `delivery_id` is derived deterministically from
    # `(target_aud, event_type, idempotency_key)` so a re-call against
    # the same domain entity dedupes via the UNIQUE constraint.
    #
    # Returns the row's `delivery_id` on success, nil on failure
    # (logged + swallowed per the additive-failure contract).
    def enqueue(target_aud, event_type, payload, idempotency_key)
      if target_aud.to_s.empty? || event_type.to_s.empty? || payload.nil?
        Rails.logger.warn(
          "[outbound-webhook-enqueue] invalid-args target_aud=#{target_aud.inspect} " \
          "event_type=#{event_type.inspect}"
        )
        return nil
      end

      payload_json = payload.is_a?(String) ? payload : JSON.generate(payload)
      delivery_id = compute_delivery_id(target_aud, event_type, idempotency_key)

      WebhookOutbox.create!(
        target_aud: target_aud,
        event_type: event_type,
        payload: payload_json,
        delivery_id: delivery_id,
        status: WebhookOutbox::STATUS_PENDING,
        attempts: 0
      )

      delivery_id
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      # `RecordNotUnique` is the desired idempotent shape — another
      # path enqueued the same (target_aud, event_type, idempotency_key)
      # tuple; the existing row's delivery_id is the same value we
      # just computed, so callers can correlate.
      Rails.logger.info(
        "[outbound-webhook-enqueue] duplicate-suppressed target_aud=#{target_aud} " \
        "event_type=#{event_type} delivery_id=#{delivery_id} reason=#{e.class.name}"
      )
      delivery_id
    rescue StandardError => e
      Rails.logger.warn(
        "[outbound-webhook-enqueue] failed target_aud=#{target_aud} " \
        "event_type=#{event_type} reason=#{e.message}"
      )
      nil
    end

    # Convenience overload for the submitter-signed event whose
    # idempotency anchor is the submitter UUID (so a re-fire against
    # the same submitter dedupes naturally).
    def enqueue_submitter_signed(submitter, payload)
      enqueue(WebhookOutbox::TARGET_DEFAULT,
              WebhookOutbox::EVENT_SUBMITTER_SIGNED,
              payload,
              "submitter:#{submitter.id}")
    end

    # Convenience overload for the submission-completed event keyed
    # on the submission UUID.
    def enqueue_submission_completed(submission, payload)
      enqueue(WebhookOutbox::TARGET_DEFAULT,
              WebhookOutbox::EVENT_SUBMISSION_COMPLETED,
              payload,
              "submission:#{submission.id}:completed")
    end

    # Convenience overload for the submission-created event.
    def enqueue_submission_created(submission, payload)
      enqueue(WebhookOutbox::TARGET_DEFAULT,
              WebhookOutbox::EVENT_SUBMISSION_CREATED,
              payload,
              "submission:#{submission.id}:created")
    end

    # Dispatch a single outbox row. The caller (drain worker) decides
    # what to do with the {DispatchResult} — this method does NOT
    # mutate the row. Returns a {DispatchResult} struct.
    def dispatch(row)
      return DispatchResult.fail('row-nil', -1) if row.nil?

      url = outbox_webhook_url
      secret = outbox_webhook_secret

      return DispatchResult.fail('config: WEBHOOK_OUTBOX_URL not configured', -1) if url.empty?
      return DispatchResult.fail('config: WEBHOOK_OUTBOX_SECRET not configured', -1) if secret.empty?

      payload = row.payload.to_s
      signature = signer.sign(payload, secret)
      return DispatchResult.fail('hmac-compute-empty', -1) if signature.empty?

      # 3-attempt retry loop, only on 429 / 5xx / network.
      last_error = nil
      last_status = -1
      MAX_DISPATCH_ATTEMPTS.times do |attempt|
        sleep(BACKOFF_SECONDS[attempt - 1]) if attempt.positive?

        begin
          resp = perform_request(url, payload, signature, row.delivery_id)
          last_status = resp.status.to_i
          return DispatchResult.ok(last_status) if (200..299).cover?(last_status)

          if last_status == 429 || (500..599).cover?(last_status)
            last_error = "transient: #{last_status}"
            next
          end

          # Non-retryable 4xx — bail out immediately.
          last_error = "non-retryable: #{last_status}"
          break
        rescue Faraday::TimeoutError => e
          last_error = "timeout: #{e.message}"
          next
        rescue Faraday::ConnectionFailed, Faraday::Error => e
          last_error = "io: #{e.message}"
          next
        rescue StandardError => e
          last_error = "runtime: #{e.message}"
          break
        end
      end

      Rails.logger.warn(
        "[outbound-webhook-dispatch] failed delivery_id=#{row.delivery_id} " \
        "status=#{last_status} reason=#{last_error}"
      )
      DispatchResult.fail(last_error || 'unknown', last_status)
    end

    # ----- internals -----

    def signer
      @signer ||= WebhookHmacSigner.new
    end

    def outbox_webhook_url
      ENV['WEBHOOK_OUTBOX_URL'].to_s.strip
    end

    def outbox_webhook_secret
      ENV['WEBHOOK_OUTBOX_SECRET'].to_s
    end

    def perform_request(url, payload, signature, delivery_id)
      conn = Faraday.new(url: url) do |f|
        f.options.timeout      = REQUEST_TIMEOUT_SECONDS
        f.options.open_timeout = REQUEST_TIMEOUT_SECONDS
        f.adapter Faraday.default_adapter
      end

      conn.post do |req|
        req.headers['Content-Type'] = 'application/json; charset=UTF-8'
        req.headers['X-Webhook-Signature'] = signature
        req.headers['X-Webhook-Delivery-Id'] = delivery_id.to_s
        req.body = payload
      end
    end

    # Test seam: tests can stub this to inject a fake conn.
    def perform_request_with_conn(conn, payload, signature, delivery_id)
      conn.post do |req|
        req.headers['Content-Type'] = 'application/json; charset=UTF-8'
        req.headers['X-Webhook-Signature'] = signature
        req.headers['X-Webhook-Delivery-Id'] = delivery_id.to_s
        req.body = payload
      end
    end

    # Deterministic UUIDv5-style derivation from
    # `(target_aud, event_type, idempotency_key)`. Same input gives the same
    # delivery_id, so a receiver can de-duplicate across emitter restarts.
    def compute_delivery_id(target_aud, event_type, idempotency_key)
      return SecureRandom.uuid if idempotency_key.to_s.empty?

      digest = Digest::SHA256.digest("#{target_aud}:#{event_type}:#{idempotency_key}")
      bytes = digest.bytes[0, 16]
      # Set version (5 — name-based SHA-1, closest analogue) + variant.
      bytes[6] = (bytes[6] & 0x0f) | 0x50
      bytes[8] = (bytes[8] & 0x3f) | 0x80
      hex = bytes.map { |b| format('%02x', b) }.join
      [hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12]].join('-')
    end

    # Result of a single `dispatch(row)` call. Two states: ok (any 2xx)
    # or failed (anything else including config errors).
    DispatchResult = Struct.new(:success, :http_status, :error, keyword_init: true) do
      def success?
        success
      end

      def self.ok(status)
        new(success: true, http_status: status, error: nil)
      end

      def self.fail(error, status)
        new(success: false, http_status: status, error: error)
      end
    end
  end
end
