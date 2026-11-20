# frozen_string_literal: true

require 'rails_helper'

# The payment webhook forwarding route was removed. Its provider path parameter
# used to be interpolated unchecked into a request to the premium service, so a
# request such as POST /webhooks/payments/%2E%2E%2F%2E%2E%2Fapi%2Fsubscriptions%2Fcancel
# reached an arbitrary POST route of that service. It must now have no route at all and
# must never produce an outbound call. (The test environment raises
# RoutingError where production answers 404.)
RSpec.describe 'Removed payment webhook route' do
  around do |example|
    saved = ENV.values_at('PREMIUM_SERVICE_URL', 'PREMIUM_API_TOKEN')
    ENV['PREMIUM_SERVICE_URL'] = 'https://premium.example.test'
    ENV['PREMIUM_API_TOKEN'] = 'test-premium-token'
    PremiumBridge.instance_variable_set(:@connection, nil)
    example.run
  ensure
    ENV['PREMIUM_SERVICE_URL'], ENV['PREMIUM_API_TOKEN'] = saved
    PremiumBridge.instance_variable_set(:@connection, nil)
  end

  [
    '/webhooks/payments/%2E%2E%2F%2E%2E%2Fapi%2Fsubscriptions%2Fcancel',
    '/webhooks/payments/stripe%3Fx%3D1',
    '/webhooks/payments/stripe'
  ].each do |path|
    it "has no route for POST #{path} and calls nothing" do
      stub = stub_request(:any, /premium\.example\.test/)

      expect do
        post path, params: '{"account_id":1}', headers: { 'CONTENT_TYPE' => 'application/json' }
      end.to raise_error(ActionController::RoutingError)
      expect(stub).not_to have_been_requested
    end
  end
end
