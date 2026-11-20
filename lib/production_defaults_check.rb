# frozen_string_literal: true

# Reports settings that make a production deployment weaker than it should be, so
# an operator sees them in the boot log instead of finding out later. It never
# changes behaviour and never stops the boot: plain-HTTP trials on a laptop are a
# legitimate use.
module ProductionDefaultsCheck
  LOCAL_HOSTS = %w[localhost 127.0.0.1 ::1].freeze

  module_function

  # @param env [#[]] the process environment
  # @return [Array<String>] one sentence per weak setting
  def warnings(env)
    list = []

    unless force_ssl?(env)
      list << 'FORCE_SSL is not set: session cookies are not marked Secure and no HSTS header is sent. ' \
              'Set FORCE_SSL to your public host name when the app is served over HTTPS.'
    end

    if LOCAL_HOSTS.include?(env['HOST'].to_s.strip.presence || 'localhost')
      list << 'HOST is not set (or is localhost): links in e-mails and shared forms will point to localhost.'
    end

    if allowed_hosts(env).empty?
      list << 'ALLOWED_HOSTS is not set: requests are accepted for any Host header. ' \
              'Set it to a comma separated list of the host names you serve.'
    end

    list
  end

  def force_ssl?(env)
    env['FORCE_SSL'].to_s.strip.present? && env['FORCE_SSL'].to_s.strip != 'false'
  end

  # Host names from ALLOWED_HOSTS ("sign.example.com, *.example.org").
  def allowed_hosts(env)
    env['ALLOWED_HOSTS'].to_s.split(',').map(&:strip).compact_blank
  end
end
