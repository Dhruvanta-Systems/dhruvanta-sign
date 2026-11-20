# frozen_string_literal: true

require 'rails_helper'

describe 'Subscriptions settings' do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }

  before do
    sign_in(user)
  end

  def stub_plan(plan, status: 'active')
    allow(PremiumBridge).to receive(:plan_for).with(account.id)
                                              .and_return({ 'plan' => plan, 'status' => status, 'features' => {} })
  end

  it 'shows the free plan when the premium service reports an inactive subscription' do
    stub_plan('free', status: 'cancelled')

    get settings_subscriptions_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Free')
  end

  it 'shows the plan the operator granted' do
    stub_plan('pro')

    get settings_subscriptions_path

    expect(response.body).to include('Pro')
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

  it 'no longer lists a Pro + AI plan' do
    expect(SubscriptionPlans.all.keys).not_to include('pro_ai')
    expect(SubscriptionPlans.all.values.flat_map(&:keys)).not_to include(:ai)
  end

  it 'does not show an Upgrade button in the settings navbar' do
    stub_plan('free')

    get settings_subscriptions_path

    expect(response.body).not_to include('btn btn-warning btn-sm')
  end
end
