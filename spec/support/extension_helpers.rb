# frozen_string_literal: true

# Helpers for specs that exercise Extensions: a clean registry per example,
# environment switches that are restored, and route reloading for the modes that
# change which routes are drawn.
module ExtensionHelpers
  def with_env(values)
    saved = values.keys.index_with { |key| ENV.fetch(key, nil) }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }

    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  # Redraws the routes under `values` (for example AUTH_MODE=external), then
  # restores the environment and the stock routes.
  def with_routes_for(values)
    with_env(values) do
      Rails.application.reload_routes!

      yield
    end
  ensure
    Rails.application.reload_routes!
  end
end

RSpec.configure do |config|
  config.include ExtensionHelpers

  config.before do
    Extensions.reset!
    RateLimit::STORE.clear
  end

  config.after do
    Extensions.reset!
  end
end
