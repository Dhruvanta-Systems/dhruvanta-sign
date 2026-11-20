# frozen_string_literal: true

require 'digest'
require 'json'

module JwtSso
  # Writes one structured JSON log line per SSO outcome, greppable as
  # `audit.jwt_sso`. This app has no generic audit table, so nothing is stored in
  # the database. Emit failures never fail the sign-in request.
  class AuditEmitter
    EVENT_SSO_RECEIVED = 'SSO_RECEIVED'
    EVENT_SSO_FAILED = 'SSO_FAILED'
    TARGET_ID_TYPE = 'SSO_HANDOFF'

    def initialize(logger: Rails.logger)
      @logger = logger
    end

    def sso_received(actor_user_id:, jti:, external_user_id:, external_tenant_id:,
                     tier: nil, ip: nil, user_agent: nil)
      emit(build_event(
             event_code: EVENT_SSO_RECEIVED, actor_user_id: actor_user_id&.to_s, jti: jti,
             verified_at: Time.now.utc.iso8601, failure_reason: nil, ip: ip, user_agent: user_agent,
             external_user_id: external_user_id, external_tenant_id: external_tenant_id, tier: tier
           ))
    end

    def sso_failed(failure_reason:, jti: nil, external_user_id: nil, external_tenant_id: nil,
                   tier: nil, ip: nil, user_agent: nil)
      emit(build_event(
             event_code: EVENT_SSO_FAILED, actor_user_id: nil, jti: jti, verified_at: nil,
             failure_reason: failure_reason, ip: ip, user_agent: user_agent,
             external_user_id: external_user_id, external_tenant_id: external_tenant_id, tier: tier
           ))
    end

    private

    def emit(event)
      @logger.info("audit.jwt_sso #{JSON.generate(event)}")
    rescue StandardError => e
      @logger.warn("audit-emit-failed event_code=#{event[:event_code]} reason=#{e.message}")
    end

    def build_event(event_code:, actor_user_id:, jti:, verified_at:, failure_reason:, ip:, user_agent:,
                    external_user_id:, external_tenant_id:, tier:)
      {
        event_code: event_code,
        actor_user_id: actor_user_id,
        target_id_type: TARGET_ID_TYPE,
        target_id_hash: sha256(jti),
        provider_ref: jti,
        verified_at: verified_at,
        failure_reason: failure_reason,
        ip: blank?(ip) ? nil : ip,
        user_agent: blank?(user_agent) ? nil : user_agent,
        emitted_at: Time.now.utc.iso8601,
        external_user_id: external_user_id,
        external_tenant_id: external_tenant_id,
        tier: tier
      }
    end

    def sha256(value)
      return nil if blank?(value)

      Digest::SHA256.hexdigest(value)
    end

    def blank?(value)
      value.nil? || value.to_s.empty?
    end
  end
end
