# frozen_string_literal: true

require 'puma/plugin'
require 'redis_client'

# Embedded Sidekiq plugin for Puma.
#
# Activation gate: this plugin runs an in-process Sidekiq alongside Puma only
# when `LOCAL_REDIS_URL` is set, which `config/dotenv.rb` does if `REDIS_URL`
# is empty, i.e. no external Redis is configured and the sibling `redis_server`
# plugin is forking a co-located `redis-server`. When an external Redis is
# configured, a dedicated `sidekiq` worker is expected to run against it, so
# the embedded worker would be a duplicate on the same queues. This mirrors the
# `LOCAL_REDIS_URL` gate in `lib/puma/plugin/redis_server.rb` so both embed
# plugins disable symmetrically.
# rubocop:disable-next Metrics
Puma::Plugin.create do
  def config(cfg)
    # Gate mirrors redis_server.rb. When an external Redis is configured
    # (LOCAL_REDIS_URL empty), defer entirely to the dedicated sidekiq worker
    # container; do not embed.
    return if ENV['LOCAL_REDIS_URL'].to_s.empty?
    return if cfg.instance_variable_get(:@options)[:workers] <= 0

    cfg.on_worker_boot { start_sidekiq! }

    cfg.on_worker_shutdown { @sidekiq&.stop }
    cfg.on_refork { @sidekiq&.stop }
  end

  def start(launcher)
    # Same gate as in `config` above.
    return if ENV['LOCAL_REDIS_URL'].to_s.empty?

    launcher.events.after_booted do
      next if Puma.stats_hash[:workers].to_i != 0

      start_sidekiq!
    end

    launcher.events.after_stopped { Thread.new { @sidekiq&.stop }.join }
    launcher.events.before_restart { Thread.new { @sidekiq&.stop }.join }
  end

  def fire_event(config, event)
    arr = config[:lifecycle_events][event]

    arr.each(&:call)

    arr.clear
  end

  def start_sidekiq!
    Thread.new do
      wait_for_redis!

      configs = Sidekiq.configure_embed do |config|
        config.logger.level = Rails.env.development? ? Logger::DEBUG : Logger::INFO
        sidekiq_config = YAML.load_file('config/sidekiq.yml')
        sidekiq_config['queues'] << 'fields' if ENV['DEMO'] == 'true'
        config.queues = sidekiq_config['queues']
        config.concurrency = ENV.fetch('SIDEKIQ_THREADS', 5).to_i
        config.merge!(sidekiq_config)
        config[:max_retries] = 13

        ActiveSupport.run_load_hooks(:sidekiq_config, config)
      end.instance_variable_get(:@config)

      fire_event(configs, :startup)

      @sidekiq = Sidekiq::Launcher.new(configs, embedded: true)

      @sidekiq.run
    end
  end

  def wait_for_redis!
    attempt = 0

    loop do
      attempt += 1

      sleep (attempt - 1) / 10.0

      RedisClient.new(url: ENV.fetch('REDIS_URL', nil)).call('GET', '1')

      break
    rescue RedisClient::CannotConnectError
      raise('Unable to connect to redis') if attempt > 30
    end
  end
end
