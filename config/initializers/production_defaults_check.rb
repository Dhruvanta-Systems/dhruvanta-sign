# frozen_string_literal: true

# Host authorization is opt-in: with ALLOWED_HOSTS set, a request whose Host header
# is not on the list gets 403 (the /up health check stays reachable).
hosts = ProductionDefaultsCheck.allowed_hosts(ENV)

if hosts.any?
  Rails.application.config.hosts.concat(hosts)
  Rails.application.config.host_authorization = { exclude: ->(request) { request.path == '/up' } }
end

# rubocop:disable Style/IfUnlessModifier
if Rails.env.production?
  ProductionDefaultsCheck.warnings(ENV).each { |message| Rails.logger.warn("[production-defaults] #{message}") }
end
# rubocop:enable Style/IfUnlessModifier
