# frozen_string_literal: true

module Extensions
  # Keeps what the plan provider said so that a request does not wait for it.
  #
  #   * an answer younger than PLAN_CACHE_TTL_SECONDS (default 60) is used as is;
  #   * when the provider fails, the last known answer is used for up to
  #     PLAN_MAX_STALE_SECONDS (default 3600) after it was fetched;
  #   * past that the result is `Plan.closed` and every gated action is refused
  #     (fail closed), until the provider answers again.
  #
  # The store is per process. Entries are tiny and a provider is expected to be
  # cheap; a shared cache is not needed for correctness.
  module PlanCache
    # After a failed fetch do not ask again for this long.
    RETRY_AFTER = 5

    Entry = Struct.new(:plan, :fetched_at)

    @entries = {}
    @retry_at = {}
    @mutex = Mutex.new

    class << self
      def ttl = seconds('PLAN_CACHE_TTL_SECONDS', 60)

      def max_stale = seconds('PLAN_MAX_STALE_SECONDS', 3600)

      def fetch(account_id)
        key = account_id.to_s
        now = Time.current
        entry, retry_at = @mutex.synchronize { [@entries[key], @retry_at[key]] }

        return entry.plan if entry && now - entry.fetched_at < ttl
        return stale_or_closed(entry, now) if retry_at && now < retry_at

        refresh(key, entry, now) do
          raw = yield
          raise ArgumentError, 'plan provider returned no plan' unless raw.is_a?(Hash)

          Plan.from(raw)
        end
      end

      def clear!
        @mutex.synchronize do
          @entries.clear
          @retry_at.clear
        end
      end

      private

      def refresh(key, entry, now)
        plan = yield
        @mutex.synchronize do
          @entries[key] = Entry.new(plan, now)
          @retry_at.delete(key)
        end
        plan
      rescue StandardError => e
        Rails.logger.warn("Extensions plan provider failed: #{e.class}")
        @mutex.synchronize { @retry_at[key] = now + RETRY_AFTER }
        stale_or_closed(entry, now)
      end

      def stale_or_closed(entry, now)
        return Plan.closed unless entry && now - entry.fetched_at <= max_stale

        entry.plan
      end

      def seconds(name, default)
        value = ENV.fetch(name, nil).to_s.strip
        value.match?(/\A\d+\z/) ? value.to_i : default
      end
    end
  end
end
