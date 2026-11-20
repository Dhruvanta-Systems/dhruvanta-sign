# frozen_string_literal: true

# Read-only view of the plan the premium service has granted this account. Plans
# are assigned by the server operator; there is nothing to buy or cancel here.
class SubscriptionsController < ApplicationController
  before_action :authorize_subscriptions!

  def index
    @current_plan_data = PremiumBridge.plan_for(current_account.id)
    @current_plan = @current_plan_data['plan'].presence || 'free'
  end

  private

  def authorize_subscriptions!
    authorize! :manage, :subscription
  end
end
