# frozen_string_literal: true

require 'digest'

# Read-only export of the local `submission_events` rows for audit aggregation by
# another service (GET /api/admin/audit_events).
#
# The export is limited to ONE account: the token names it in its account claim
# (SERVICE_JWT_ACCOUNT_CLAIM, default `account_id`) and a token without that claim
# is refused. An `account_id` query parameter may only repeat the token's account;
# any other value answers 403. The token's `audit.read` scope is the permission.
#
# Auth is a service JWT (not a Devise session), verified by
# {JwtSso::ServiceClientJwtVerifier}: the audience and the audit scope are taken
# from SERVICE_JWT_AUDIENCE and SERVICE_JWT_AUDIT_SCOPE. Failures render an
# `application/problem+json` body with a 401, 403 or 503.
#
# Each row is translated into a flat audit shape: `event_code` is the event type
# upper-cased with a `DOCUSEAL_` prefix, `target_id_hash` is the SHA-256 of the
# submission id, `actor_user_id` is the submitter id (nil for system events) and
# the free-form `data` column rides in `metadata`.
module Api
  module Admin
    class AuditEventsController < ActionController::API
      MAX_PAGE_SIZE = 200
      DEFAULT_PAGE_SIZE = 50

      TARGET_ID_TYPE_SUBMISSION = 'DOCUSEAL_SUBMISSION'
      EVENT_CODE_PREFIX = 'DOCUSEAL_'
      ACTOR_ROLE_SUBMITTER = 'SUBMITTER'
      ACTOR_ROLE_SYSTEM = 'SYSTEM'

      before_action :verify_service_client_token!

      rescue_from JwtSso::ServiceClientJwtVerifier::VerificationError do |error|
        render json: problem_detail(error), status: error.http_status,
               content_type: 'application/problem+json'
      end

      def index
        page = [params[:page].to_i, 0].max
        size = bounded_size(params[:size])

        scope = SubmissionEvent.where(account_id: permitted_account_id!)
        scope = filter_event_type(scope, params[:event_type])
        scope = filter_start_date(scope, params[:start_date])
        scope = filter_end_date(scope, params[:end_date])

        total = scope.count
        rows = scope.order(created_at: :desc).offset(page * size).limit(size)
        content = rows.map { |row| serialise(row) }

        render json: {
          content: content,
          totalElements: total,
          number: page,
          size: size,
          numberOfElements: content.size
        }
      end

      private

      def verify_service_client_token!
        token = bearer_from_authorization
        @verified = service_client_verifier.verify(token)
      end

      def service_client_verifier
        @service_client_verifier ||= JwtSso::ServiceClientJwtVerifier.new
      end

      def bearer_from_authorization
        header = request.headers['Authorization'].to_s
        return nil if header.empty?
        return nil unless header.start_with?('Bearer ')

        header.sub(/^Bearer\s+/, '')
      end

      def bounded_size(raw)
        n = raw.to_i
        return DEFAULT_PAGE_SIZE if n <= 0

        [n, MAX_PAGE_SIZE].min
      end

      def filter_event_type(scope, raw)
        return scope if raw.blank?

        scope.where(event_type: raw.to_s)
      end

      # The one account this token may read. A query parameter naming another
      # account is refused, not silently ignored, so a caller cannot believe it
      # received another tenant's rows.
      def permitted_account_id!
        account_id = @verified.account_id
        requested = params[:account_id]

        if requested.present? && requested.to_s != account_id.to_s
          raise JwtSso::ServiceClientJwtVerifier::VerificationError.new('service-token-wrong-account', :forbidden)
        end

        account_id
      end

      def filter_start_date(scope, raw)
        return scope if raw.blank?

        ts = parse_iso(raw)
        ts ? scope.where('created_at >= ?', ts) : scope
      end

      def filter_end_date(scope, raw)
        return scope if raw.blank?

        ts = parse_iso(raw)
        ts ? scope.where('created_at < ?', ts) : scope
      end

      def parse_iso(raw)
        Time.iso8601(raw.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      # Translate one `SubmissionEvent` row to the flat audit shape. The `id` is
      # the local bigint, returned as a string so the envelope stays stable.
      def serialise(row)
        actor_user_id = row.submitter_id&.to_s
        actor_role = actor_user_id.nil? ? ACTOR_ROLE_SYSTEM : ACTOR_ROLE_SUBMITTER
        event_code = "#{EVENT_CODE_PREFIX}#{row.event_type.to_s.upcase}"
        submission_hash = row.submission_id ? Digest::SHA256.hexdigest(row.submission_id.to_s) : nil

        {
          id: row.id.to_s,
          created_at: row.created_at&.utc&.iso8601,
          actor_user_id: actor_user_id,
          actor_role: actor_role,
          event_code: event_code,
          target_id_type: TARGET_ID_TYPE_SUBMISSION,
          target_id_hash: submission_hash,
          request_id: nil,
          metadata: build_metadata(row),
          audience: nil,
          source: nil
        }
      end

      def build_metadata(row)
        meta = {
          'docuseal_event_type' => row.event_type,
          'submission_id' => row.submission_id,
          'submitter_id' => row.submitter_id,
          'account_id' => row.account_id,
          'event_timestamp' => row.event_timestamp&.utc&.iso8601
        }
        # `data` is a serialized-as-JSON Hash on the model; nil-safe.
        meta['data'] = row.data if row.data.present?
        meta
      end

      def problem_detail(error)
        {
          type: 'about:blank',
          title: 'Audit events request rejected',
          status: Rack::Utils::SYMBOL_TO_STATUS_CODE[error.http_status] || 401,
          code: error.code,
          detail: error.code
        }
      end
    end
  end
end
