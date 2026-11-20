# frozen_string_literal: true

require 'rails_helper'

# Coverage for Outbound::WebhookHmacSigner (HMAC-SHA256, lowercase hex, no prefix).
RSpec.describe Outbound::WebhookHmacSigner do
  subject(:signer) { described_class.new }

  describe '#sign' do
    it 'returns lowercase HMAC-SHA256 hex with no prefix' do
      sig = signer.sign('{"hello":"world"}', 'shared-secret')

      expect(sig).to match(/\A[0-9a-f]{64}\z/)
      expect(sig).not_to start_with('sha256=')
    end

    it 'is deterministic for the same payload + secret' do
      a = signer.sign('payload', 'secret')
      b = signer.sign('payload', 'secret')
      expect(a).to eq(b)
    end

    it 'returns empty string when the secret is blank or nil' do
      expect(signer.sign('payload', nil)).to eq('')
      expect(signer.sign('payload', '')).to eq('')
    end

    it 'differs across distinct payloads' do
      a = signer.sign('payload-a', 'secret')
      b = signer.sign('payload-b', 'secret')
      expect(a).not_to eq(b)
    end
  end

  describe '#verify' do
    it 'verifies a sign output round-trip (success)' do
      payload = '{"hello":"world"}'
      sig = signer.sign(payload, 'secret')

      expect(signer.verify(payload, 'secret', sig)).to be true
    end

    it 'is case-insensitive on the candidate hex' do
      sig = signer.sign('p', 'k').upcase
      expect(signer.verify('p', 'k', sig)).to be true
    end

    it 'rejects a tampered signature' do
      sig = signer.sign('p', 'k')
      tampered = sig.sub(sig[0], sig[0] == 'a' ? 'b' : 'a')
      expect(signer.verify('p', 'k', tampered)).to be false
    end

    it 'rejects when the secret differs' do
      sig = signer.sign('p', 'right-secret')
      expect(signer.verify('p', 'wrong-secret', sig)).to be false
    end
  end
end
