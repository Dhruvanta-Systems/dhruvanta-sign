# frozen_string_literal: true

module SubscriptionPlans
  PLANS = {
    'free' => {
      title: 'Free',
      price_monthly: 0,
      docs: '10 / month',
      users: '1',
      ai: false,
      api: false
    },
    'starter' => {
      title: 'Starter',
      price_monthly: 499,
      docs: '100 / month',
      users: '3',
      ai: false,
      api: true
    },
    'pro' => {
      title: 'Pro',
      price_monthly: 1999,
      docs: 'Unlimited',
      users: '10',
      ai: false,
      api: true
    },
    'pro_ai' => {
      title: 'Pro + AI',
      price_monthly: 3499,
      docs: 'Unlimited',
      users: '10',
      ai: true,
      api: true
    },
    'enterprise' => {
      title: 'Enterprise',
      price_monthly: nil,
      docs: 'Unlimited',
      users: 'Unlimited',
      ai: true,
      api: true
    }
  }.freeze

  module_function

  def all
    PLANS
  end

  def find(plan_name)
    PLANS[plan_name.to_s] || PLANS['free']
  end
end
