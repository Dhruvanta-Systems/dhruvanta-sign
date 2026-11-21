# frozen_string_literal: true

# The OpenID Connect relying party endpoints (drawn only with AUTH_MODE=external):
#
#   GET    /auth/oidc/start               begin a sign-in (also where "please sign in" leads)
#   GET    /auth/oidc/callback            the redirect URI: finish the sign-in or a step-up
#   GET    /auth/oidc/step_up             re-authenticate for one sensitive action
#   DELETE /auth/oidc/logout              RP-initiated logout
#   POST   /auth/oidc/backchannel-logout  the provider ends sessions (server to server)
class OidcController < ApplicationController
  skip_before_action :authenticate_user!
  skip_before_action :maybe_redirect_to_setup
  skip_before_action :enforce_oidc_session
  skip_authorization_check
  skip_forgery_protection only: :backchannel_logout

  before_action :require_configured

  rescue_from Oidc::Error do |error|
    render_failure(error)
  end

  def start
    redirect_to Oidc::Flow.start(session, return_to: safe_return_to(params[:return_to] || session[:user_return_to])),
                allow_other_host: true
  end

  def callback
    result = Oidc::Flow.complete(session, request.query_parameters.with_indifferent_access)

    if result.flow['step_up']
      finish_step_up(result)
    else
      finish_sign_in(result)
    end
  end

  def step_up
    action = params[:action_name].to_s
    registry = OidcSession.for_token(session[:oidc_session])

    return redirect_to(oidc_start_path) unless registry && current_user
    return head :not_found unless Oidc::Config.step_up?(action)

    action_id = SecureRandom.urlsafe_base64(16)
    nonce = Oidc::StepUp.nonce(action_id, registry.id)
    step_up = { action:, action_id:, nonce: }

    redirect_to Oidc::Flow.start(session, return_to: safe_return_to(params[:return_to]), step_up:),
                allow_other_host: true
  end

  def destroy
    OidcSession.for_token(session[:oidc_session])&.revoke!
    id_token = session[:oidc_id_token]
    sign_out(:user)
    reset_session

    redirect_to logout_url(id_token), allow_other_host: true
  end

  def backchannel_logout
    Oidc::BackchannelLogout.call(params[:logout_token])

    response.headers['Cache-Control'] = 'no-store'
    head :ok
  rescue Oidc::Error => e
    Rails.logger.warn("Oidc back-channel logout refused: #{e.code}")
    response.headers['Cache-Control'] = 'no-store'
    head :bad_request
  end

  private

  def require_configured
    head :not_found unless Oidc::Config.enabled?
  end

  def finish_sign_in(result)
    claims = result.claims
    user = Oidc::Linker.call(claims)
    return_to = result.flow['return_to']

    reset_session
    sign_in(user)

    registry, token = OidcSession.open!(user:, issuer: Oidc::Config.issuer, sub: claims['sub'].to_s, sid: claims['sid'],
                                        auth_time: claims['auth_time'], acr: claims['acr'], amr: claims['amr'])
    session[:oidc_session] = token
    session[:oidc_id_token] = result.id_token
    Rails.logger.info("Oidc sign-in user=#{user.id} session=#{registry.id}")

    redirect_to safe_return_to(return_to)
  end

  def finish_step_up(result)
    step_up = result.flow['step_up']
    registry = OidcSession.for_token(session[:oidc_session])

    raise Oidc::Error.new('step_up_without_session', :unauthorized) unless registry && registry.sub == result.claims['sub']
    raise Oidc::Error, 'step_up_nonce_mismatch' unless result.claims['nonce'] == Oidc::StepUp.nonce(step_up['action_id'], registry.id)
    raise Oidc::Error.new('step_up_acr_too_low', :forbidden) unless Oidc::Config.acr_satisfies?(result.claims['acr'])

    registry.update!(acr: result.claims['acr'], auth_time: Time.zone.at(result.claims['auth_time'].to_i),
                     amr: Array(result.claims['amr']).map(&:to_s))
    Oidc::StepUp.grant!(session, action: step_up['action'])

    redirect_to safe_return_to(result.flow['return_to'])
  end

  # RP-initiated logout (OpenID Connect RP-Initiated Logout 1.0).
  def logout_url(id_token)
    endpoint = Oidc::Provider.end_session_endpoint
    return Oidc::Config.post_logout_redirect_uri if endpoint.blank?

    uri = URI.parse(endpoint)
    query = URI.decode_www_form(uri.query.to_s) + [['id_token_hint', id_token], ['client_id', Oidc::Config.client_id],
                                                   ['post_logout_redirect_uri', Oidc::Config.post_logout_redirect_uri],
                                                   ['state', SecureRandom.urlsafe_base64(16)]].compact_blank
    uri.query = URI.encode_www_form(query)
    uri.to_s
  rescue Oidc::Error
    Oidc::Config.post_logout_redirect_uri
  end

  # Only a path on this app: never an address that could send a person elsewhere.
  def safe_return_to(value)
    path = value.to_s
    return root_path unless path.start_with?('/') && !path.start_with?('//') && path.exclude?('\\') && path.exclude?("\n")

    path
  end

  def render_failure(error)
    Rails.logger.warn("Oidc sign-in refused: #{error.code}")

    render html: helpers.safe_join([helpers.tag.p("Sign-in failed (#{error.message})."),
                                    helpers.link_to('Try again', oidc_start_path)]),
           status: error.http_status, layout: false
  end
end
