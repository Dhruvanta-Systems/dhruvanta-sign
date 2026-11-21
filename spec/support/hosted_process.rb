# frozen_string_literal: true

require 'open3'
require 'tempfile'

# Runs a Ruby script inside a separate, freshly booted HOSTED_MODE app (test
# environment). Everything hosted mode requires is supplied through the environment
# (the HTTP implementation for plan, notifier and otp, OpenID Connect settings with a
# client secret file, a non-disk storage service), so the boot check passes. Returns the
# JSON the script prints after "RESULT:".
module HostedProcess
  def hosted_process_env
    @hosted_process_secret ||= Tempfile.new('hosted-secret').tap do |file|
      file.write("a-client-secret\n")
      file.flush
    end

    {
      'RAILS_ENV' => 'test', 'HOSTED_MODE' => 'true', 'AUTH_MODE' => 'external',
      'PREMIUM_SERVICE_URL' => 'https://ext.example.test', 'EXTENSIONS_HTTP_PORTS' => 'plan,notifier,otp',
      'OIDC_ISSUER' => 'https://op.example.com', 'OIDC_CLIENT_ID' => 'sign-app',
      'OIDC_CLIENT_SECRET_FILE' => @hosted_process_secret.path
    }
  end

  def run_in_hosted_process(script, extra_env = {})
    output, status = Open3.capture2e(hosted_process_env.merge(extra_env), 'bin/rails', 'runner', script,
                                     chdir: Rails.root.to_s)

    raise "hosted process failed: #{output}" unless status.success?

    JSON.parse(output[/RESULT:(.*)$/, 1])
  end
end

RSpec.configure { |config| config.include HostedProcess }
