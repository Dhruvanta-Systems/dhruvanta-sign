# frozen_string_literal: true

require 'rails_helper'

describe 'Subscriptions settings' do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }

  before do
    sign_in(user)
  end

  it 'shows free plan state for inactive premium subscriptions' do
    allow(PremiumBridge).to receive(:plan_for).with(account.id).and_return({
                                                                             'plan' => 'free',
                                                                             'status' => 'cancelled',
                                                                             'features' => {}
                                                                           })

    get settings_subscriptions_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Current plan:', 'Free')
  end

  it 'does not show a checkout success message until the premium service confirms the upgraded plan' do
    allow(PremiumBridge).to receive(:plan_for).with(account.id).and_return({
                                                                             'plan' => 'free',
                                                                             'status' => 'cancelled',
                                                                             'features' => {}
                                                                           })

    get settings_subscriptions_path, params: { upgraded: 'pro' }

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('Plan activated successfully.')
  end

  it 'shows a checkout success message after the premium service confirms the upgraded plan' do
    allow(PremiumBridge).to receive(:plan_for).with(account.id).and_return({
                                                                             'plan' => 'pro',
                                                                             'status' => 'active',
                                                                             'features' => { 'features' => ['basic_signing'] }
                                                                           })

    get settings_subscriptions_path, params: { upgraded: 'pro' }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Plan activated successfully.')
    expect(response.body).to include('Current plan:', 'Pro')
  end

  it 'redirects to the private checkout URL when premium checkout starts' do
    expect(PremiumBridge).to receive(:create_checkout).with(hash_including(
                                                              account_id: account.id,
                                                              plan: 'pro',
                                                              provider: 'razorpay',
                                                              email: user.email,
                                                              success_url: a_string_including('upgraded=pro'),
                                                              cancel_url: a_string_ending_with('/settings/subscriptions')
                                                            )).and_return({ 'checkout_url' => 'https://checkout.example.test/session' })

    post settings_subscriptions_path, params: { plan: 'pro', provider: 'razorpay' }

    expect(response).to redirect_to('https://checkout.example.test/session')
  end

  it 'fails closed when premium checkout is unavailable' do
    allow(PremiumBridge).to receive(:create_checkout).and_return({})

    post settings_subscriptions_path, params: { plan: 'pro', provider: 'razorpay' }

    expect(response).to redirect_to(settings_subscriptions_path)
    expect(flash[:alert]).to eq('Unable to start upgrade. Check premium service connectivity.')
  end

  it 'fails closed when premium cancellation is unavailable' do
    allow(PremiumBridge).to receive(:cancel_subscription).with(account_id: account.id).and_return({})

    delete settings_subscription_path(id: 'pro')

    expect(response).to redirect_to(settings_subscriptions_path)
    expect(flash[:alert]).to eq('Unable to cancel plan. Check premium service connectivity.')
  end

  it 'shows a confirmation when premium cancellation succeeds' do
    allow(PremiumBridge).to receive(:cancel_subscription).with(account_id: account.id).and_return({ 'status' => 'cancelled' })

    delete settings_subscription_path(id: 'pro')

    expect(response).to redirect_to(settings_subscriptions_path)
    expect(flash[:notice]).to eq('Plan cancelled.')
  end
end
