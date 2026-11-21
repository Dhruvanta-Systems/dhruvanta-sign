# frozen_string_literal: true

require 'rails_helper'

describe Oidc::StepUp do
  describe '.nonce' do
    it 'is the same for the same action and session' do
      first = described_class.nonce('action-1', 7)

      expect(described_class.nonce('action-1', 7)).to eq(first)
    end

    it 'is bound to the action: another action id gives another nonce' do
      expect(described_class.nonce('action-1', 7)).not_to eq(described_class.nonce('action-2', 7))
    end

    it 'is bound to the session: another session gives another nonce' do
      expect(described_class.nonce('action-1', 7)).not_to eq(described_class.nonce('action-1', 8))
    end

    it 'cannot be forged by moving the separator' do
      expect(described_class.nonce('action-1', 17)).not_to eq(described_class.nonce('action-11', 7))
    end

    it 'depends on the app secret' do
      first = described_class.nonce('a', 1)
      allow(Rails.application).to receive(:secret_key_base).and_return('another-secret')

      expect(described_class.nonce('a', 1)).not_to eq(first)
    end
  end

  describe '.consume!' do
    it 'accepts a fresh proof once and for its own action only' do
      store = {}
      described_class.grant!(store, action: 'webhooks')

      expect(described_class.consume!(store, 'api_token')).to be(false) # and it is spent
      expect(described_class.consume!(store, 'webhooks')).to be(false)

      described_class.grant!(store, action: 'webhooks')
      expect(described_class.consume!(store, 'webhooks')).to be(true)
      expect(described_class.consume!(store, 'webhooks')).to be(false)
    end

    it 'refuses a proof older than ten minutes' do
      store = { oidc_step_up: { 'action' => 'webhooks', 'at' => 11.minutes.ago.to_i } }

      expect(described_class.consume!(store, 'webhooks')).to be(false)
    end
  end
end
