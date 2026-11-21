# frozen_string_literal: true

# Read-only view of the plan the plan provider reports for this account: its name,
# limits and how much of each is used. Nothing is priced or sold here; plans and
# prices belong to the plan provider.
class SubscriptionsController < ApplicationController
  before_action :authorize_subscriptions!

  def index
    @plan = Extensions.plan_for(current_account)
    @usage = @plan.limits.keys.index_with { |key| Extensions::Usage.count(current_account, key) }
  end

  private

  def authorize_subscriptions!
    authorize! :manage, :subscription
  end
end
