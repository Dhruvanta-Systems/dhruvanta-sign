# frozen_string_literal: true

require 'faraday'
require 'json'
require 'securerandom'

module Outbound
  # Client for a generic HTTP transactional-email API.
  #
  # Request:  POST {MAIL_API_BASE_URL}{MAIL_API_PATH}   (path defaults to /email)
  #           body `{templateKey, recipient, variables, tenantId, userId, idempotencyKey}`
  # Response: 2xx with `{deliveryId, status, queuedAt}`
  # Auth:     bearer token from {Outbound::OauthTokenClient}
  #
  # Retry policy: 3 attempts with 250ms / 1s / 4s backoff on 429, 5xx and network
  # errors; any other 4xx fails immediately. On a 4xx the `title` and `detail` of
  # an RFC 7807 problem body are added to the error message for the operator, but
  # the status code alone decides whether to retry.
  #
  # Every send logs one structured JSON line ("audit.mail_api_email"). Failures
  # raise {EmailDeliveryError}.
  #
  # Test seam: the `http:` constructor argument accepts a stubbed Faraday
  # connection.
  class HttpMailApiClient
    DEFAULT_MAX_ATTEMPTS = 3
    DEFAULT_HTTP_TIMEOUT_SECONDS = 10
    BACKOFF_SECONDS = [0.25, 1.0, 4.0].freeze
    DEFAULT_EMAIL_PATH = '/email'

    class EmailDeliveryError < StandardError; end

    DeliveryReceipt = Struct.new(:delivery_id, :status, :queued_at, keyword_init: true) do
      def success?
        !delivery_id.to_s.empty?
      end
    end

    def initialize(token_client: nil, http: nil, logger: Rails.logger)
      @token_client = token_client || Outbound::OauthTokenClient.new
      @http = http
      @logger = logger
    end

    # Sends a transactional email via mail API. Returns a
    # {DeliveryReceipt} on 2xx. Raises {EmailDeliveryError} on
    # exhausted retries, non-retryable 4xx, network failure, or
    # malformed response.
    #
    # @param template_key [String]   template key known to the mail API
    # @param recipient    [String]   RFC-5322 recipient address (non-blank)
    # @param variables    [Hash, nil] Handlebars merge-tag values (defaults to {})
    # @param tenant_id    [String]   scoping tenant; REQUIRED
    # @param user_id      [String, nil] actor user id; nullable for system origins
    # @param idempotency_key [String] caller-stable key; the mail API should
    #        de-duplicate on it and return the original result for a repeat call
    def send(template_key:, recipient:, tenant_id:, variables: nil, user_id: nil, idempotency_key: nil)
      validate_inputs!(template_key, recipient, tenant_id, idempotency_key)
      idempotency_key ||= SecureRandom.uuid

      url = full_url
      raise EmailDeliveryError, 'MAIL_API_BASE_URL is required' if url.nil?

      token = @token_client.access_token
      body = encode_body(template_key, recipient, variables, tenant_id, user_id, idempotency_key)

      attempts = max_attempts
      last_error = nil
      attempts.times do |attempt|
        sleep(BACKOFF_SECONDS[attempt - 1]) if attempt.positive?
        begin
          resp = perform_request(url, body, token)
          status = resp.status.to_i
          if (200..299).cover?(status)
            receipt = parse_receipt(resp.body, template_key)
            emit_audit('SUCCESS', template_key, recipient, idempotency_key, receipt: receipt, http_status: status)
            return receipt
          end
          if status == 429 || (500..599).cover?(status)
            last_error = "transient: #{status}"
            next
          end
          # 4xx other than 429 — fail closed, parse RFC-7807 if present.
          msg = build_problem_message(resp, status, template_key)
          emit_audit('FAIL', template_key, recipient, idempotency_key, http_status: status, reason: msg)
          raise EmailDeliveryError, msg
        rescue Faraday::TimeoutError => e
          last_error = "timeout: #{e.message}"
          next
        rescue Faraday::ConnectionFailed, Faraday::Error => e
          last_error = "io: #{e.message}"
          next
        end
      end

      emit_audit('FAIL', template_key, recipient, idempotency_key, http_status: -1, reason: last_error)
      raise EmailDeliveryError,
            "mail API retries exhausted at #{email_path} (template_key=#{template_key}) — last_error=#{last_error}"
    end

    private

    def perform_request(url, body, token)
      conn = @http || default_http
      conn.post(url) do |req|
        req.headers['Authorization'] = "Bearer #{token}"
        req.headers['Content-Type']  = 'application/json'
        req.headers['Accept']        = 'application/json'
        req.options.timeout      = http_timeout_seconds
        req.options.open_timeout = http_timeout_seconds
        req.body = body
      end
    end

    def default_http
      Faraday.new do |f|
        f.adapter Faraday.default_adapter
      end
    end

    def encode_body(template_key, recipient, variables, tenant_id, user_id, idempotency_key)
      payload = {
        'templateKey' => template_key,
        'recipient' => recipient,
        'variables' => variables.is_a?(Hash) ? variables : {},
        'tenantId' => tenant_id.to_s,
        'idempotencyKey' => idempotency_key
      }
      payload['userId'] = user_id.to_s unless user_id.nil? || user_id.to_s.empty?
      JSON.generate(payload)
    end

    def parse_receipt(body, template_key)
      json =
        begin
          JSON.parse(body.to_s)
        rescue JSON::ParserError => e
          raise EmailDeliveryError,
                "mail API returned malformed JSON at #{email_path} (template_key=#{template_key}): #{e.message}"
        end
      delivery_id = json['deliveryId'].to_s
      status      = json['status'].to_s
      if delivery_id.empty?
        raise EmailDeliveryError,
              "mail API response missing deliveryId (template_key=#{template_key})"
      end
      if status.empty?
        raise EmailDeliveryError,
              "mail API response missing status (template_key=#{template_key})"
      end

      queued_at_raw = json['queuedAt']
      queued_at =
        if queued_at_raw.is_a?(String) && !queued_at_raw.empty?
          begin
            Time.parse(queued_at_raw)
          rescue ArgumentError
            nil
          end
        end

      DeliveryReceipt.new(delivery_id: delivery_id, status: status, queued_at: queued_at)
    end

    def build_problem_message(resp, status, template_key)
      content_type = if resp.respond_to?(:headers)
                       resp.headers.to_h.transform_keys(&:to_s).fetch('Content-Type',
                                                                      '')
                     else
                       ''
                     end
      content_type ||= ''
      base = "mail API rejected email send HTTP #{status} at #{email_path} (template_key=#{template_key})"
      return "#{base}: #{truncate(resp.body.to_s)}" unless content_type.include?('application/problem+json')

      problem =
        begin
          JSON.parse(resp.body.to_s)
        rescue JSON::ParserError
          nil
        end
      return "#{base}: #{truncate(resp.body.to_s)}" if problem.nil?

      title  = problem['title'].to_s
      detail = problem['detail'].to_s
      "#{base}: #{[title, detail].reject(&:empty?).join(' — ')}"
    end

    def emit_audit(outcome, template_key, recipient, idempotency_key, http_status: nil, receipt: nil, reason: nil)
      event = {
        event_code: 'MAIL_API_SEND',
        actor_user_id: nil,
        target_id_type: 'EMAIL_DELIVERY',
        target_id_hash: nil,
        provider_ref: receipt&.delivery_id,
        verified_at: Time.now.utc.iso8601,
        failure_reason: reason,
        emitted_at: Time.now.utc.iso8601,
        template_key: template_key,
        recipient_hash: recipient.to_s.empty? ? nil : Digest::SHA256.hexdigest(recipient.to_s),
        idempotency_key_hash: Digest::SHA256.hexdigest(idempotency_key.to_s),
        http_status: http_status,
        outcome: outcome
      }
      @logger&.info("audit.mail_api_email #{JSON.generate(event)}")
    rescue StandardError => e
      @logger&.warn("[mail-api-audit-emit] failed reason=#{e.message}")
    end

    def validate_inputs!(template_key, recipient, tenant_id, _idempotency_key)
      raise EmailDeliveryError, 'template_key must be non-empty' if blank?(template_key)
      raise EmailDeliveryError, 'recipient must be non-empty' if blank?(recipient)
      raise EmailDeliveryError, 'tenant_id must be non-empty' if blank?(tenant_id)
    end

    def email_path
      path = ENV['MAIL_API_PATH'].to_s.strip
      path = DEFAULT_EMAIL_PATH if path.empty?
      path.start_with?('/') ? path : "/#{path}"
    end

    def full_url
      base = ENV['MAIL_API_BASE_URL'].to_s
      return nil if base.empty?

      base = base.chomp('/')
      "#{base}#{email_path}"
    end

    def max_attempts
      [ENV.fetch('MAIL_API_MAX_ATTEMPTS', DEFAULT_MAX_ATTEMPTS).to_i, 1].max
    end

    def http_timeout_seconds
      ENV.fetch('MAIL_API_HTTP_TIMEOUT_SECONDS', DEFAULT_HTTP_TIMEOUT_SECONDS).to_i
    end

    def truncate(value)
      value.length > 256 ? "#{value[0, 256]}..." : value
    end

    def blank?(value)
      value.nil? || value.to_s.empty?
    end
  end
end
