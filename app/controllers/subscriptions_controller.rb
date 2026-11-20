# frozen_string_literal: true

class SubscriptionsController < ApplicationController
  before_action :authorize_subscriptions!

  def index
    @current_plan_data = PremiumBridge.plan_for(current_account.id)
    @current_plan = @current_plan_data['plan'].presence || 'free'
    @plans = SubscriptionPlans.all.except('free')
    @checkout_provider = 'stripe'
    @success_message = 'Plan activated successfully.' if upgraded_plan_confirmed?(params[:upgraded].to_s)
  end

  def create
    plan = params.require(:plan).to_s
    raise ActionController::BadRequest, 'Unknown plan' unless SubscriptionPlans.all.key?(plan)

    result = PremiumBridge.create_checkout(
      account_id: current_account.id,
      plan:,
      provider: params[:provider].presence || 'stripe',
      email: true_user.email,
      success_url: subscriptions_return_url(plan),
      cancel_url: settings_subscriptions_url
    )

    checkout_url = result.is_a?(Hash) ? result['checkout_url'].presence : nil

    if checkout_url
      redirect_to checkout_url, allow_other_host: true
    else
      redirect_to settings_subscriptions_path,
                  alert: 'Unable to start upgrade. Check premium service connectivity.'
    end
  end

  def destroy
    result = PremiumBridge.cancel_subscription(account_id: current_account.id)

    if result.is_a?(Hash) && result['status'] == 'cancelled'
      redirect_to settings_subscriptions_path, notice: 'Plan cancelled.'
    else
      redirect_to settings_subscriptions_path,
                  alert: 'Unable to cancel plan. Check premium service connectivity.'
    end
  end

  private

  def authorize_subscriptions!
    authorize! :manage, :subscription
  end

  def subscriptions_return_url(plan)
    uri = URI.parse(settings_subscriptions_url)
    query = Rack::Utils.parse_nested_query(uri.query)
    query['upgraded'] = plan
    uri.query = query.to_query
    uri.to_s
  end

  def upgraded_plan_confirmed?(plan)
    return false unless plan.present? && plan != 'free'
    return false unless SubscriptionPlans.all.key?(plan)
    return false unless @current_plan_data['status'].to_s == 'active'

    @current_plan == plan
  end
end
