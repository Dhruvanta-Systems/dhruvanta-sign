# frozen_string_literal: true

# Generic JWT single sign-on receiver. An external identity provider signs a
# short-lived JWT for a person; this controller verifies it (see
# {JwtSso::HandoffService} and {JwtSso::Config}), signs the person in and, on
# first sight, provisions the user.
#
# The flow is bound to the browser that started it, so a token cannot be pushed
# into somebody else's browser (login CSRF) and never travels in a URL:
#
#   GET  /sso/start
#       Stores a random `state` in an encrypted, HttpOnly, SameSite=Lax cookie
#       and redirects to JWT_SSO_LOGIN_URL with `state` and `redirect_uri`.
#       The identity provider must echo `state` into the token's nonce claim.
#
#   POST /sso/handoff   form fields: token, state
#       Browser landing (the identity provider auto-submits a form). The `state`
#       field must equal the cookie and the token's nonce claim; the cookie is
#       then consumed. Success redirects to the root page; failure redirects to
#       the sign-in page with `?reason=sso-failed&code=<machine-code>`.
#
#   POST /api/auth/sso-handoff   body: { "token": "<jwt>", "state": "<state>" }
#       Same checks, JSON answer: 200 with `{ user_id, email, ... }` on success,
#       an `application/problem+json` body on failure.
#
# There is deliberately no GET variant of the handoff: a token in a query string
# lands in access logs, browser history and Referer headers.
#
# The receiver is disabled (404) until JWT_SSO_ISSUER, JWT_SSO_JWKS_URL and
# JWT_SSO_AUDIENCE are set. CSRF tokens are not used on the POST actions (the
# identity provider cannot have one); the state cookie plus the signed nonce
# claim take their place, and the JWT signature checked against the issuer's
# published keys is the trust anchor.
class JwtSsoHandoffController < ApplicationController
  skip_before_action :authenticate_user!
  skip_before_action :maybe_redirect_to_setup
  skip_authorization_check
  # Sign-out is a normal session action and keeps CSRF protection.
  skip_forgery_protection only: %i[start show create]

  rescue_from JwtSso::HandoffService::HandoffError do |error|
    handle_handoff_error(error)
  end

  STATE_COOKIE = :sso_state
  STATE_TTL = 10.minutes

  # GET /sso/start
  def start
    return head :not_found unless Extensions.configured?(:auth) && JwtSso::Config.login_url.present?

    state = SecureRandom.urlsafe_base64(32)
    cookies.encrypted[STATE_COOKIE] = {
      value: state, httponly: true, same_site: :lax, secure: request.ssl?, expires: STATE_TTL.from_now
    }

    redirect_to sso_login_redirect_url(state), allow_other_host: true
  end

  # POST /sso/handoff  form: token, state
  def show
    accept_handoff!(params[:token].to_s)

    redirect_to root_path
  end

  # POST /api/auth/sso-handoff  body: { token: "...", state: "..." }
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

  # DELETE /sso/sign_out (drawn with AUTH_MODE=external, where it is `destroy_user_session`)
  def destroy
    sign_out(:user)

    redirect_to root_path
  end

  private

  def sso_login_redirect_url(state)
    uri = URI.parse(JwtSso::Config.login_url)
    query = URI.decode_www_form(uri.query.to_s)
    query << ['state', state] << ['redirect_uri', jwt_sso_handoff_url]
    uri.query = URI.encode_www_form(query)
    uri.to_s
  end

  # Consumes the state cookie (single use) and returns it, or raises when the
  # browser did not start the flow or the posted state is not the cookie's.
  def consume_state!
    expected = cookies.encrypted[STATE_COOKIE].to_s
    cookies.delete(STATE_COOKIE)

    posted = params[:state].to_s
    if expected.empty? || posted.empty? || !ActiveSupport::SecurityUtils.secure_compare(posted, expected)
      raise JwtSso::HandoffService::HandoffError.new('sso-handoff-state-mismatch', :unauthorized)
    end

    expected
  end

  def accept_handoff!(token)
    service = handoff_service
    verified =
      begin
        raise JwtSso::HandoffService::NotConfiguredError unless Extensions.configured?(:auth)

        service.verify_handoff(token, expected_nonce: consume_state!)
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
    # The auth_provider port; stock is JwtSso::HandoffService.
    @handoff_service ||= Extensions.auth
  end

  def handle_handoff_error(error)
    respond_to do |format|
      format.html do
        if Extensions.external_auth?
          # There is no local sign-in page to go back to (and the sign-in route would
          # start the flow again), so say what happened and offer a retry.
          render html: helpers.safe_join([helpers.tag.p("Sign-in failed (#{error.code})."),
                                          helpers.link_to('Try again', jwt_sso_start_path)]),
                 status: error.http_status, layout: false
        else
          redirect_to(new_user_session_path(reason: 'sso-failed', code: error.code))
        end
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
