# frozen_string_literal: true

# Generic JWT single sign-on receiver. An external identity provider signs a
# short-lived JWT for a person; this controller verifies it (see
# {JwtSso::HandoffService} and {JwtSso::Config}), signs the person in and, on
# first sight, provisions the user.
#
#   GET  /sso/handoff?token=<jwt>
#       Browser landing. On success sets the session and redirects to the root
#       page; on failure redirects to the sign-in page with
#       `?reason=sso-failed&code=<machine-code>`.
#
#   POST /api/auth/sso-handoff   body: { "token": "<jwt>" }
#       JSON variant. 200 with `{ user_id, email, ... }` on success, an
#       `application/problem+json` body on failure.
#
# The receiver is disabled (404) until JWT_SSO_ISSUER, JWT_SSO_JWKS_URL and
# JWT_SSO_AUDIENCE are set. CSRF protection is skipped on both actions: they exist
# to give an unauthenticated browser a fresh session, and the JWT signature
# checked against the issuer's published keys is the trust anchor.
class JwtSsoHandoffController < ApplicationController
  skip_before_action :authenticate_user!
  skip_before_action :maybe_redirect_to_setup
  skip_authorization_check
  skip_forgery_protection

  rescue_from JwtSso::HandoffService::HandoffError do |error|
    handle_handoff_error(error)
  end

  # GET /sso/handoff?token=<jwt>
  def show
    accept_handoff!(params[:token].to_s)

    redirect_to root_path
  end

  # POST /api/auth/sso-handoff  body: { token: "..." }
  def create
    user, verified = accept_handoff!(params[:token].to_s)

    render json: {
      user_id: user.uuid,
      email: user.email,
      external_user_id: verified.subject,
      external_tenant_id: verified.tenant_id,
      tier: verified.tier
    }, status: :ok
  end

  private

  def accept_handoff!(token)
    service = handoff_service
    verified =
      begin
        service.verify_handoff(token)
      rescue JwtSso::HandoffService::HandoffError => e
        service.audit_failed(e.code, ip: request.remote_ip, user_agent: request.user_agent)
        raise
      end

    user = service.lookup_or_provision_user(verified)
    sign_in(user)
    service.audit_received(verified, user, ip: request.remote_ip, user_agent: request.user_agent)
    [user, verified]
  end

  def handoff_service
    @handoff_service ||= JwtSso::HandoffService.new
  end

  def handle_handoff_error(error)
    respond_to do |format|
      format.html do
        redirect_to(new_user_session_path(reason: 'sso-failed', code: error.code))
      end
      format.any do
        render json: problem_detail(error), status: error.http_status, content_type: 'application/problem+json'
      end
    end
  end

  def problem_detail(error)
    {
      type: 'about:blank',
      title: 'SSO handoff rejected',
      status: Rack::Utils::SYMBOL_TO_STATUS_CODE[error.http_status] || 401,
      code: error.code,
      detail: error.code
    }
  end
end
