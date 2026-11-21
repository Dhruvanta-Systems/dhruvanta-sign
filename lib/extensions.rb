# frozen_string_literal: true

# The single place where this app talks to anything operator specific.
#
# Every capability that a hosted deployment usually wants to supply itself (who
# signs people in, how mail and one-time codes are sent, which plan an account is
# on, where files are stored, ...) is a named PORT. A port is any object that
# answers the methods listed below. With nothing registered every port falls back
# to a stock default, so a plain install behaves like upstream.
#
#   Extensions.register(:notifier, MyNotifier.new)   # in-process adapter
#   Extensions.configured?(:notifier)                # => true
#   Extensions.require!(:auth, :notifier)            # raises MissingPorts when absent
#
# Ports (short name => interface name) and what they answer:
#
#   auth          auth_provider          verify_handoff(token, expected_nonce:) -> handoff,
#                                        lookup_or_provision_user(handoff) -> User,
#                                        audit_received(...), audit_failed(...)
#   notifier      notifier               deliver(channel:, to:, ...) (see Extensions::NotifierDeliveryMethod)
#   otp           otp_provider           send_code(subject:, purpose:, channel:, to:, locale:, account_id:),
#                                        verify(subject:, code:, purpose:) -> true/false
#   plan          plan_provider          account_plan(account_id) -> { plan:, status:, features:, limits:, suspended: }
#   storage       storage_service        name -> Active Storage service name
#   event_sink    event_sink             emit(event, payload)
#   verification  verification_provider  start(payload) -> Hash, status(submitter_slug) -> Hash
#   payment_step  payment_step_provider  create(submitter, field) -> Hash, status(session_id) -> Hash
#
# Adapters registered with `register` run inside the Rails process. Anything
# operator specific that is not generic belongs behind HTTP instead (see
# Extensions::Http, which makes PremiumBridge the default HTTP implementation).
#
# Environment:
#
#   HOSTED_MODE=true        fail-closed profile, see Extensions::HostedBoot
#   AUTH_MODE=external      local sign-in routes are not drawn; sign-in only by the JWT handoff
#   EXTENSIONS_HTTP_PORTS   which ports the HTTP service (PREMIUM_SERVICE_URL) supplies,
#                           default "plan,event_sink,verification"
#   PLAN_CACHE_TTL_SECONDS  how long a plan answer is fresh (default 60)
#   PLAN_MAX_STALE_SECONDS  how long the last known plan may be used when the provider
#                           is down; past that every gated action fails closed (default 3600)
#   ABUSE_CONTROLS=true     per-account and per-IP rate limits outside hosted mode
module Extensions
  PORTS = {
    auth: :auth_provider,
    notifier: :notifier,
    otp: :otp_provider,
    plan: :plan_provider,
    storage: :storage_service,
    event_sink: :event_sink,
    verification: :verification_provider,
    payment_step: :payment_step_provider
  }.freeze

  DEFAULT_HTTP_PORTS = %i[plan event_sink verification].freeze

  # Raised when an extension is asked to do something it is not configured for.
  NotConfigured = Class.new(StandardError)

  # Raised by `require!` (and so by the hosted-mode boot check).
  class MissingPorts < StandardError
    attr_reader :ports

    def initialize(ports)
      @ports = ports
      super("Missing extensions: #{ports.join(', ')}")
    end
  end

  # Base class of every refusal made by the plan gate. The message is safe to
  # show to a person.
  class GateError < StandardError; end

  # Hosted mode only: the shared rate-limit store is down, so the action is refused.
  class RateLimitUnavailable < GateError
    def initialize(msg = 'Rate limiting is unavailable. Please try again later.')
      super
    end
  end

  class AccountSuspended < GateError
    def initialize(msg = 'This account is suspended.')
      super
    end
  end

  class PlanUnavailable < GateError
    def initialize(msg = 'The plan service is unavailable. Please try again later.')
      super
    end
  end

  class LimitExceeded < GateError
    attr_reader :key, :limit

    def initialize(key, limit)
      @key = key
      @limit = limit
      super("Your plan limit for #{key} (#{limit}) has been reached.")
    end
  end

  @registry = {}
  @mutex = Mutex.new

  class << self
    # ---- profile switches (read live so they can be flipped in specs) --------

    def hosted?
      ENV['HOSTED_MODE'].to_s.strip.casecmp?('true')
    end

    def external_auth?
      ENV['AUTH_MODE'].to_s.strip.casecmp?('external')
    end

    # Per-account and per-IP rate limits on sending and creating submissions.
    def abuse_controls?
      hosted? || ENV['ABUSE_CONTROLS'].to_s.strip.casecmp?('true')
    end

    # ---- registry -------------------------------------------------------------

    def register(name, implementation)
      key = normalize(name)
      @mutex.synchronize { @registry[key] = implementation }
      implementation
    end

    def unregister(name)
      @mutex.synchronize { @registry.delete(normalize(name)) }
    end

    # Forget every registered adapter and the plan cache (used by specs).
    def reset!
      @mutex.synchronize { @registry.clear }
      PlanCache.clear!
    end

    def registered?(name)
      @mutex.synchronize { @registry.key?(normalize(name)) }
    end

    # True when something other than the stock default answers for the port.
    def configured?(name)
      key = normalize(name)
      return true if registered?(key)
      return true if http_port?(key)
      return JwtSso::Config.enabled? if key == :auth
      return !storage_service_name.to_s.in?(%w[disk local]) if key == :storage

      false
    end

    def require!(*names)
      missing = names.flatten.map { |name| normalize(name) }.reject { |name| configured?(name) }

      raise MissingPorts, missing if missing.any?

      true
    end

    # The object that answers for a port: a registered adapter, else the HTTP
    # implementation when enabled for it, else the stock default.
    def implementation(name)
      key = normalize(name)
      registered = @mutex.synchronize { @registry[key] }
      return registered if registered
      return Http.provider(key) if http_port?(key)

      Stock.provider(key)
    end

    PORTS.each_key do |port|
      define_method(port) { implementation(port) }
    end

    def http_port?(key)
      Http::PROVIDERS.key?(key) && PremiumBridge.enabled? && http_ports.include?(key)
    end

    def http_ports
      raw = ENV.fetch('EXTENSIONS_HTTP_PORTS', nil)
      return DEFAULT_HTTP_PORTS if raw.blank?

      raw.split(',').filter_map { |item| normalize(item.strip, strict: false) }
    end

    # ---- hooks (fire and forget, never raise into the request) -----------------

    def emit(event, payload = {})
      event_sink.emit(event.to_s, payload)
      nil
    rescue StandardError => e
      Rails.logger.warn("Extensions.emit #{event} failed: #{e.class}")
      nil
    end

    # ---- storage ---------------------------------------------------------------

    def storage_service_name
      registered = @mutex.synchronize { @registry[:storage] }
      return registered.name.to_s if registered

      Rails.application.config.active_storage.service.to_s
    end

    # ---- plan gate -------------------------------------------------------------

    # The cached, normalized plan of an account (an Extensions::Plan).
    def plan_for(account)
      account_id = account.respond_to?(:id) ? account.id : account

      PlanCache.fetch(account_id) { plan.account_plan(account_id) }
    end

    # Does the account's plan include the feature?
    def feature?(account, key)
      return false unless configured?(:plan)

      current = plan_for(account)

      current.usable? && current.feature?(key)
    end

    def suspended?(account)
      configured?(:plan) && plan_for(account).suspended?
    end

    # Would one more (or `add` more) of `key` stay inside the plan? Checked
    # BEFORE the cost of the action is incurred. A limit the plan does not name
    # is unlimited; a missing or too-old plan answer fails closed.
    def within_limit?(account, key, add: 1)
      return true unless configured?(:plan)

      current = plan_for(account)
      return false unless current.usable?

      limit = current.limit(key)
      return true if limit.nil?

      Usage.count(account, key) + add <= limit
    end

    private

    def normalize(name, strict: true)
      sym = name.to_s.to_sym
      return sym if PORTS.key?(sym)

      found = PORTS.key(sym)
      return found if found
      return nil unless strict

      raise ArgumentError, "unknown extension port: #{name}"
    end
  end
end
