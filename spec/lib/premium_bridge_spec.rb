# frozen_string_literal: true

require 'rails_helper'

describe PremiumBridge do
  around do |example|
    premium_url = ENV.fetch('PREMIUM_SERVICE_URL', nil)
    premium_token = ENV.fetch('PREMIUM_API_TOKEN', nil)

    reset_premium_bridge!
    example.run
  ensure
    ENV['PREMIUM_SERVICE_URL'] = premium_url
    ENV['PREMIUM_API_TOKEN'] = premium_token
    reset_premium_bridge!
  end

  describe 'path segments' do
    before { configure_premium_service }

    it 'sends no request for an event name that could change the path' do
      ['../../api/subscriptions/cancel', 'stripe?x=1', 'a/b', '..', '%2E%2E%2F'].each do |event|
        described_class.notify(event, {})
      end

      expect(a_request(:any, /premium\.example\.test/)).not_to have_been_made
    end

    it 'sends no request for an unsafe account id' do
      result = described_class.plan_for('1/../../api/subscriptions/cancel')

      expect(a_request(:any, /premium\.example\.test/)).not_to have_been_made
      expect(result).to be_a(Hash)
    end

    it 'still reaches the plan endpoint for a numeric account id' do
      stub_request(:get, 'https://premium.example.test/api/premium/account/42/plan')
        .to_return(status: 200, headers: { 'Content-Type' => 'application/json' }, body: '{"plan":"pro"}')

      expect(described_class.plan_for(42)).to include('plan' => 'pro')
    end
  end

  def configure_premium_service
    ENV['PREMIUM_SERVICE_URL'] = 'https://premium.example.test'
    ENV['PREMIUM_API_TOKEN'] = 'test-premium-token'
    reset_premium_bridge!
  end

  def reset_premium_bridge!
    PremiumBridge.instance_variable_set(:@connection, nil)
    PremiumBridge.instance_variable_set(:@failure_count, 0)
    PremiumBridge.instance_variable_set(:@circuit_open_at, nil)
  end

  describe 'removed purchase calls' do
    it 'has no checkout or cancellation call left' do
      expect(described_class).not_to respond_to(:create_checkout)
      expect(described_class).not_to respond_to(:cancel_subscription)
    end
  end
end
