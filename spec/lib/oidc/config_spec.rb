# frozen_string_literal: true

require 'rails_helper'

describe Oidc::Config do
  describe '.scopes' do
    it 'defaults to openid email profile' do
      expect(described_class.scopes).to eq(%w[openid email profile])
    end

    it 'never asks for offline_access (there are no refresh tokens) and always asks for openid' do
      with_env('OIDC_SCOPES' => 'email offline_access') do
        expect(described_class.scopes).to eq(%w[openid email])
      end
    end
  end

  describe '.acr_satisfies?' do
    around do |example|
      with_env('OIDC_STEP_UP_ACR' => 'b', 'OIDC_STEP_UP_ACR_ORDER' => 'a,b,c') { example.run }
    end

    it 'accepts the required value and stronger ones' do
      expect(described_class.acr_satisfies?('b')).to be(true)
      expect(described_class.acr_satisfies?('c')).to be(true)
    end

    it 'refuses weaker, unknown and missing values' do
      expect(described_class.acr_satisfies?('a')).to be(false)
      expect(described_class.acr_satisfies?('z')).to be(false)
      expect(described_class.acr_satisfies?(nil)).to be(false)
    end

    it 'needs an exact match when no order is configured' do
      with_env('OIDC_STEP_UP_ACR_ORDER' => nil) do
        expect(described_class.acr_satisfies?('b')).to be(true)
        expect(described_class.acr_satisfies?('c')).to be(false)
      end
    end
  end

  describe '.step_up?' do
    it 'is off unless an acr and the action are configured' do
      expect(described_class.step_up?('webhooks')).to be(false)

      with_env('OIDC_STEP_UP_ACR' => 'b', 'OIDC_STEP_UP_ACTIONS' => 'webhooks') do
        expect(described_class.step_up?('webhooks')).to be(true)
        expect(described_class.step_up?('api_token')).to be(false)
      end
    end
  end

  describe '.secret_file_error' do
    it 'names a missing, unreadable or empty secret file' do
      with_env('OIDC_CLIENT_SECRET_FILE' => nil) { expect(described_class.secret_file_error).to match(/not set/) }
      with_env('OIDC_CLIENT_SECRET_FILE' => '/nonexistent') { expect(described_class.secret_file_error).to match(/not readable/) }
      Tempfile.create('empty') do |file|
        with_env('OIDC_CLIENT_SECRET_FILE' => file.path) { expect(described_class.secret_file_error).to match(/empty/) }
      end
    end

    it 'is nil for a good file, and the secret is read from it with the newline stripped' do
      Tempfile.create('secret') do |file|
        file.write("the-secret\n")
        file.flush

        with_env('OIDC_CLIENT_SECRET_FILE' => file.path) do
          expect(described_class.secret_file_error).to be_nil
          expect(described_class.client_secret).to eq('the-secret')
        end
      end
    end
  end
end
