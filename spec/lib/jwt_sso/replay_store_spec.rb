# frozen_string_literal: true

require 'rails_helper'

describe JwtSso::ReplayStore do
  let(:jti) { "jti-#{SecureRandom.hex(6)}" }

  describe 'outside hosted mode' do
    it 'uses the Rails cache' do
      cache = ActiveSupport::Cache::MemoryStore.new

      expect(described_class.claim?(jti, ttl: 60, cache:)).to be(true)
      expect(described_class.claim?(jti, ttl: 60, cache:)).to be(false)
    end

    it 'refuses a cache that does not keep writes' do
      expect { described_class.claim?(jti, ttl: 60, cache: ActiveSupport::Cache::NullStore.new) }
        .to raise_error(described_class::Unavailable)
    end
  end

  describe 'in hosted mode' do
    around { |example| with_env('HOSTED_MODE' => 'true') { example.run } }

    it 'remembers a jti in the shared Redis, so a replay is refused' do
      use_test_redis!

      expect(described_class.claim?(jti, ttl: 60)).to be(true)
      expect(described_class.claim?(jti, ttl: 60)).to be(false)
    end

    it 'does not use the per-process cache' do
      use_test_redis!
      cache = ActiveSupport::Cache::MemoryStore.new

      described_class.claim?(jti, ttl: 60, cache:)

      expect(cache.exist?("sso_handoff_jti:#{jti}")).to be(false)
    end

    it 'fails closed when the shared store is down' do
      allow(Sidekiq).to receive(:redis).and_raise(RedisClient::CannotConnectError, 'down')

      expect { described_class.claim?(jti, ttl: 60) }.to raise_error(described_class::Unavailable)
    end

    it 'turns a down store into a 503 handoff error' do
      allow(Sidekiq).to receive(:redis).and_raise(RedisClient::CannotConnectError, 'down')
      service = JwtSso::HandoffService.new

      expect { service.send(:validate_and_capture_jti!, { 'jti' => jti }) }
        .to raise_error(JwtSso::HandoffService::HandoffError) { |error|
          expect(error.code).to eq('sso-handoff-replay-store-unavailable')
          expect(error.http_status).to eq(:service_unavailable)
        }
    end
  end

  describe 'two app processes' do
    it 'share one memory of used tokens' do
      script = <<~RUBY
        puts "RESULT:" + JSON.generate(ok: JwtSso::ReplayStore.claim?('#{jti}', ttl: 60))
      RUBY
      env = { 'REDIS_URL' => test_redis_url }

      first = run_in_hosted_process(script, env)
      second = run_in_hosted_process(script, env)

      expect([first['ok'], second['ok']]).to eq([true, false])
    end
  end
end
