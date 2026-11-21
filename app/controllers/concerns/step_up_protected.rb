# frozen_string_literal: true

# Makes an action need a fresh second-factor proof (Oidc::StepUp) when the deployment
# lists it in OIDC_STEP_UP_ACTIONS. Without external sign-in, or when the action is not
# listed, it does nothing.
#
#   require_step_up :api_token, only: :create
module StepUpProtected
  extend ActiveSupport::Concern

  class_methods do
    def require_step_up(action, **)
      before_action(**) { enforce_step_up!(action) }
    end
  end

  private

  def enforce_step_up!(action)
    return unless Extensions.external_auth? && Oidc::Config.step_up?(action)
    return if Oidc::StepUp.consume!(session, action)

    back = request.get? || request.head? ? request.fullpath : (URI.parse(request.referer.to_s).path.presence || root_path)

    redirect_to oidc_step_up_path(action_name: action, return_to: back)
  rescue URI::InvalidURIError
    redirect_to oidc_step_up_path(action_name: action, return_to: root_path)
  end
end
