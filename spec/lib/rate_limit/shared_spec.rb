# frozen_string_literal: true

require 'rails_helper'
require 'open3'

describe RateLimit::Shared do
  let(:key) { "spec-#{SecureRandom.hex(6)}" }

  describe 'counting in the shared store' do
    before { use_test_redis! }

    it 'allows up to the limit and refuses the next call' do
      3.times { expect(described_class.call(key, limit: 3, ttl: 60)).to be(true) }

      expect { described_class.call(key, limit: 3, ttl: 60) }.to raise_error(RateLimit::LimitApproached)
    end

    it 'keeps separate counters per key' do
      3.times { described_class.call(key, limit: 3, ttl: 60) }

      expect(described_class.call("#{key}-other", limit: 3, ttl: 60)).to be(true)
    end

    it 'expires the counter with its window' do
      described_class.call(key, limit: 3, ttl: 60)

      redis_keys = RedisClient.new(url: test_redis_url).call('KEYS', "dsign:rl:#{key}:*")

      expect(redis_keys.size).to eq(1)
      expect(RedisClient.new(url: test_redis_url).call('TTL', redis_keys.first)).to be_between(1, 60)
    end
  end

  describe 'two app processes' do
    def run_process(account_id, hits)
      script = <<~RUBY
        results = #{hits}.times.map do
          Extensions::Gate.rate_limit!(account: #{account_id}, ip: '10.1.1.#{rand(250)}')
          'ok'
        rescue RateLimit::LimitApproached
          'limited'
        end
        puts "RESULT:\#{results.join(',')}"
      RUBY
      env = { 'REDIS_URL' => test_redis_url, 'ABUSE_CONTROLS' => 'true', 'RATE_LIMIT_ACCOUNT' => '3',
              'RATE_LIMIT_IP' => '1000', 'RAILS_ENV' => 'test' }
      output, status = Open3.capture2e(env, 'bin/rails', 'runner', script, chdir: Rails.root.to_s)

      raise "process failed: #{output}" unless status.success?

      output[/RESULT:(\S+)/, 1].split(',')
    end

    it 'share one counter: hits in the second process count against the first' do
      account_id = SecureRandom.random_number(1_000_000_000)

      first = run_process(account_id, 2)
      second = run_process(account_id, 2)

      expect(first).to eq(%w[ok ok])
      expect(second).to eq(%w[ok limited])
    end
  end

  describe 'when the store is down' do
    before { allow(Sidekiq).to receive(:redis).and_raise(RedisClient::CannotConnectError, 'down') }

    it 'refuses in hosted mode (fail closed), even for the first call' do
      with_env('HOSTED_MODE' => 'true') do
        expect { described_class.call(key, limit: 100, ttl: 60) }.to raise_error(Extensions::RateLimitUnavailable)
      end
    end

    it 'refuses a send through the gate in hosted mode' do
      with_env('HOSTED_MODE' => 'true') do
        expect { Extensions::Gate.rate_limit!(account: 1, ip: '10.0.0.1') }
          .to raise_error(Extensions::RateLimitUnavailable)
      end
    end

    it 'falls back to the per-process store when not hosted, and still limits' do
      with_env('HOSTED_MODE' => nil) do
        2.times { described_class.call(key, limit: 2, ttl: 60) }

        expect { described_class.call(key, limit: 2, ttl: 60) }.to raise_error(RateLimit::LimitApproached)
      end
    end
  end
end
