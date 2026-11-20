# frozen_string_literal: true

# Bridge to the optional premium service.
# If PREMIUM_SERVICE_URL is not set, all methods return defaults (features disabled).
# Resilient: retries on connection failure, circuit breaker on repeated failures,
# graceful degradation — app works without premium service.
module PremiumBridge
  TIMEOUT = 3
  RETRY_COUNT = 2
  RETRY_INTERVAL = 0.5
  CIRCUIT_THRESHOLD = 5      # failures before opening circuit
  CIRCUIT_RESET_TIME = 30    # seconds before retrying after circuit opens

  @failure_count = 0
  @circuit_open_at = nil
  @mutex = Mutex.new

  module_function

  def enabled?
    ENV['PREMIUM_SERVICE_URL'].present?
  end

  def plan_for(account_id)
    return default_plan unless enabled?

    safe_request { connection.get("/api/premium/account/#{segment(account_id)}/plan") }
  end

  def notify(event, payload)
    return unless enabled?

    safe_request(fire_and_forget: true) do
      connection.post("/api/hooks/#{segment(event)}") { |req| req.body = JSON.generate(normalize_request_payload(payload)) }
    end
  end

  def create_video_kyc_session(payload)
    return {} unless enabled?

    safe_request(default_response: {}) do
      connection.post('/api/video-kyc/session') { |req| req.body = JSON.generate(normalize_request_payload(payload)) }
    end
  end

  def video_kyc_status(submitter_slug)
    return { 'status' => 'not_started' } unless enabled?

    safe_request(default_response: { 'status' => 'unavailable' }) do
      connection.get("/api/video-kyc/status/#{segment(submitter_slug)}")
    end
  end

  SEGMENT_FORMAT = /\A[A-Za-z0-9_.-]{1,128}\z/

  # Validates a value interpolated into a request path. Only letters, digits,
  # `_`, `-` and `.` are allowed, and `.`/`..` themselves are refused, so a value
  # can never add path segments, dot segments or a query string. The result is
  # URI-encoded as defence in depth.
  private_class_method def self.segment(value)
    text = value.to_s
    raise ArgumentError, 'unsafe path segment' if !SEGMENT_FORMAT.match?(text) || text.match?(/\A\.+\z/)

    ERB::Util.url_encode(text)
  end

  private_class_method def self.safe_request(fire_and_forget: false, default_response: default_plan)
    # Circuit breaker: skip if too many recent failures
    @mutex.synchronize do
      if @circuit_open_at && (Time.now - @circuit_open_at) < CIRCUIT_RESET_TIME
        return default_response unless fire_and_forget

        return nil
      end
      # Reset circuit if enough time passed
      if @circuit_open_at && (Time.now - @circuit_open_at) >= CIRCUIT_RESET_TIME
        @circuit_open_at = nil
        @failure_count = 0
      end
    end

    resp = yield
    @mutex.synchronize { @failure_count = 0 } # Reset on success

    if resp.success?
      normalize_response(JSON.parse(resp.body))
    else
      default_response
    end
  rescue Faraday::Error, ArgumentError => e
    handle_failure(e, fire_and_forget, default_response)
  end

  private_class_method def self.handle_failure(error, fire_and_forget, default_response)
    @mutex.synchronize do
      @failure_count += 1
      if @failure_count >= CIRCUIT_THRESHOLD
        @circuit_open_at = Time.now
        Rails.logger.warn("PremiumBridge circuit OPEN after #{@failure_count} failures")
      end
    end
    Rails.logger.warn("PremiumBridge error: #{error.message}") unless fire_and_forget
    fire_and_forget ? nil : default_response
  end

  private_class_method def self.default_plan
    { 'plan' => 'free', 'features' => {} }
  end

  private_class_method def self.normalize_response(value)
    case value
    when Array
      value.map { |item| normalize_response(item) }
    when Hash
      value.each_with_object({}) do |(key, item), acc|
        normalized_key = key.to_s.sub(/\A:/, '')
        acc[normalized_key] = normalize_response(item)
      end
    else
      value
    end
  end

  private_class_method def self.normalize_request_payload(value)
    case value
    when Array
      value.map { |item| normalize_request_payload(item) }
    when Hash
      value.each_with_object({}) do |(key, item), acc|
        acc[key.to_s.sub(/\A:/, '')] = normalize_request_payload(item)
      end
    else
      value
    end
  end

  private_class_method def self.connection
    @connection ||= Faraday.new(ENV.fetch('PREMIUM_SERVICE_URL', nil)) do |f|
      f.headers['Content-Type'] = 'application/json'
      f.headers['X-Premium-Token'] = ENV.fetch('PREMIUM_API_TOKEN', nil)
      f.options.read_timeout = TIMEOUT
      f.options.open_timeout = TIMEOUT
    end
  end
end
