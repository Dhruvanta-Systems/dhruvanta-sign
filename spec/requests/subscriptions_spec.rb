# frozen_string_literal: true

require 'rails_helper'

describe 'Subscriptions settings' do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }

  before do
    sign_in(user)
  end

  def stub_plan(plan, status: 'active', limits: {})
    provider = Fakes::PlanProvider.new(default: { plan:, status:, features: [], limits: })
    Extensions.register(:plan, provider)
  end

  it 'shows the free plan when the premium service reports an inactive subscription' do
    stub_plan('free', status: 'cancelled')

    get settings_subscriptions_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('<h2 class="text-2xl font-bold">Free</h2>')
  end

  it 'shows the plan the operator granted' do
    stub_plan('pro')

    get settings_subscriptions_path

    expect(response.body).to include('<h2 class="text-2xl font-bold">Pro</h2>')
  end

  it 'offers nothing to buy: no upgrade, cancel or checkout control, and no plan cards' do
    stub_plan('pro')

    get settings_subscriptions_path

    expect(response.body).not_to match(/Upgrade|Cancel current plan|checkout|Pro \+ AI|Contact sales|Rs \d/i)
    expect(response.body).not_to include('AI:')
    expect(response.body).not_to include('<form action="/settings/subscriptions"')
  end

  it 'has no route to start a checkout or cancel a plan' do
    expect { post settings_subscriptions_path, params: { plan: 'pro' } }.to raise_error(ActionController::RoutingError)
    expect { delete '/settings/subscriptions/pro' }.to raise_error(ActionController::RoutingError)
  end

  it 'carries no bundled plan names or prices: those come from the plan provider' do
    expect(defined?(SubscriptionPlans)).to be_nil
    expect(Rails.root.join('lib/subscription_plans.rb')).not_to exist

    stub_plan('pro')
    get settings_subscriptions_path

    expect(response.body).not_to match(/\b(499|1999|1,999)\b|price_monthly|Pro \+ AI/)
  end

  it 'shows the limits and the usage the plan provider reports' do
    stub_plan('starter', limits: { docs: 100, users: nil })

    get settings_subscriptions_path

    expect(response.body).to include('Docs: <strong>0 / 100</strong>')
    expect(response.body).to include('Users: <strong>Unlimited</strong>')
  end

  it 'does not show an Upgrade button in the settings navbar' do
    stub_plan('free')

    get settings_subscriptions_path

    expect(response.body).not_to include('btn btn-warning btn-sm')
  end
end
