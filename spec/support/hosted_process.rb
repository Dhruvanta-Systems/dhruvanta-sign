# frozen_string_literal: true

require 'open3'

# Runs a Ruby script inside a separate, freshly booted HOSTED_MODE app (test
# environment). Everything hosted mode requires is supplied through the environment
# (the HTTP implementation for plan, notifier and otp, the JWT handoff for auth, a
# non-disk storage service), so the boot check passes. Returns the JSON the script
# prints after "RESULT:".
module HostedProcess
  BASE_ENV = {
    'RAILS_ENV' => 'test', 'HOSTED_MODE' => 'true', 'AUTH_MODE' => 'external',
    'PREMIUM_SERVICE_URL' => 'https://ext.example.test', 'EXTENSIONS_HTTP_PORTS' => 'plan,notifier,otp',
    'JWT_SSO_ISSUER' => 'https://idp.example.test', 'JWT_SSO_JWKS_URL' => 'https://idp.example.test/jwks',
    'JWT_SSO_AUDIENCE' => 'sign-app', 'JWT_SSO_LOGIN_URL' => 'https://account.example.test/signin'
  }.freeze

  def run_in_hosted_process(script, extra_env = {})
    output, status = Open3.capture2e(BASE_ENV.merge(extra_env), 'bin/rails', 'runner', script, chdir: Rails.root.to_s)

    raise "hosted process failed: #{output}" unless status.success?

    JSON.parse(output[/RESULT:(.*)$/, 1])
  end
end

RSpec.configure { |config| config.include HostedProcess }
