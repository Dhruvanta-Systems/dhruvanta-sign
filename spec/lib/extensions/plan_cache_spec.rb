# frozen_string_literal: true

require 'rails_helper'

describe Extensions::PlanCache do
  include ActiveSupport::Testing::TimeHelpers

  let(:account) { create(:account) }
  let(:provider) { Fakes::PlanProvider.new }

  before do
    Extensions.register(:plan, provider)
  end

  around do |example|
    with_env('PLAN_CACHE_TTL_SECONDS' => '60', 'PLAN_MAX_STALE_SECONDS' => '3600') { example.run }
  end

  it 'asks the provider once while the answer is fresh' do
    2.times { Extensions.plan_for(account) }

    expect(provider.calls.size).to eq(1)
  end

  it 'asks again once the answer is older than the TTL' do
    Extensions.plan_for(account)

    travel_to(61.seconds.from_now) { Extensions.plan_for(account) }

    expect(provider.calls.size).to eq(2)
  end

  it 'keeps serving the last known plan while the provider is down' do
    provider.set(account.id, { plan: 'pro', status: 'active', features: %w[analytics], limits: {} })
    expect(Extensions.feature?(account, 'analytics')).to be(true)

    provider.fail_with = StandardError.new('provider down')

    travel_to(10.minutes.from_now) do
      expect(Extensions.plan_for(account).name).to eq('pro')
      expect(Extensions.feature?(account, 'analytics')).to be(true)
    end
  end

  it 'fails closed once the last known plan is older than the maximum stale age' do
    provider.set(account.id, { plan: 'pro', status: 'active', features: %w[analytics], limits: {} })
    Extensions.plan_for(account)
    provider.fail_with = StandardError.new('provider down')

    travel_to(61.minutes.from_now) do
      plan = Extensions.plan_for(account)

      expect(plan).to be_unavailable
      expect(Extensions.feature?(account, 'analytics')).to be(false)
      expect(Extensions.within_limit?(account, :docs)).to be(false)
    end
  end

  it 'fails closed when the provider has never answered' do
    provider.fail_with = StandardError.new('provider down')

    expect(Extensions.plan_for(account)).to be_unavailable
    expect(Extensions.within_limit?(account, :sends)).to be(false)
  end

  it 'does not hammer a provider that is down: it waits before asking again' do
    provider.fail_with = StandardError.new('provider down')

    3.times { Extensions.plan_for(account) }

    expect(provider.calls.size).to eq(1)
  end

  it 'recovers as soon as the provider answers again' do
    provider.fail_with = StandardError.new('provider down')
    expect(Extensions.plan_for(account)).to be_unavailable

    provider.fail_with = nil

    travel_to(10.seconds.from_now) { expect(Extensions.plan_for(account)).not_to be_unavailable }
  end

  it 'treats an answer that is not a plan as a failure, not as a plan' do
    allow(provider).to receive(:account_plan).and_return(nil)

    expect(Extensions.plan_for(account)).to be_unavailable
  end

  it 'reads the TTL and the stale age from the environment' do
    with_env('PLAN_CACHE_TTL_SECONDS' => '5') do
      Extensions.plan_for(account)
      travel_to(6.seconds.from_now) { Extensions.plan_for(account) }

      expect(provider.calls.size).to eq(2)
    end
  end
end
