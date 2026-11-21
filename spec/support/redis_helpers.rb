# frozen_string_literal: true

# A real Redis for the specs that need one (TEST_REDIS_URL). On CI it is a service;
# a missing one fails there instead of skipping, so a spec cannot go quiet.
module RedisHelpers
  def test_redis_url
    url = ENV.fetch('TEST_REDIS_URL', nil)

    raise 'TEST_REDIS_URL is not set (CI must provide a Redis)' if url.blank? && ENV['CI'].present?

    skip 'TEST_REDIS_URL is not set' if url.blank?

    url
  end

  # Makes Sidekiq.redis (what RateLimit::Shared uses) talk to the test Redis.
  def use_test_redis!
    client = RedisClient.new(url: test_redis_url)
    allow(Sidekiq).to receive(:redis).and_yield(client)

    client
  end
end

RSpec.configure { |config| config.include RedisHelpers }
