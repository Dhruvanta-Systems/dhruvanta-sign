# frozen_string_literal: true

require 'rails_helper'

# In hosted mode the session cookie carries the __Host- prefix (Secure, Path=/, no
# Domain). The session store is configured at boot, so these specs boot a hosted app
# in a separate process and read its response headers. The sign-in state itself lives
# in that session, not in a cookie of its own.
describe 'Hosted cookies' do
  def request_in_hosted_process(extra_env = {})
    script = <<~RUBY
      https = ActionDispatch::Integration::Session.new(Rails.application)
      https.https!
      https.get '/settings/profile' # not signed in: the redirect keeps the return path in the session
      secure = { status: https.response.status, cookies: Array(https.response.headers['set-cookie']).join("\\n"),
                 location: https.response.headers['location'] }
      plain = ActionDispatch::Integration::Session.new(Rails.application) # plain http, no https!
      plain.get '/settings/profile'
      puts "RESULT:" + JSON.generate(secure:, plain: Array(plain.response.headers['set-cookie']).join("\\n"))
    RUBY

    run_in_hosted_process(script, extra_env)
  end

  def cookie_lines(text)
    text.split("\n").map(&:strip).compact_blank
  end

  let(:result) { @result ||= request_in_hosted_process }

  it 'names the session cookie with the __Host- prefix: Secure, Path=/, no Domain, HttpOnly, SameSite=Lax' do
    line = cookie_lines(result['secure']['cookies']).find { |c| c.start_with?('__Host-') && c.include?('session') }

    expect(line).to be_present
    attributes = line.downcase.split(';').map(&:strip)
    expect(attributes).to include('secure', 'path=/', 'httponly', 'samesite=lax')
    expect(attributes.grep(/\Adomain=/)).to be_empty
  end

  it 'sets no unprefixed cookie at all' do
    names = cookie_lines(result['secure']['cookies']).map { |c| c.split('=').first }

    expect(names).not_to be_empty
    expect(names.reject { |name| name.start_with?('__Host-') }).to be_empty
  end

  it 'marks the session cookie Secure even when the app is reached over plain http (a proxy hides the scheme)' do
    line = cookie_lines(result['plain']).find { |c| c.start_with?('__Host-') }

    expect(line.downcase.split(';').map(&:strip)).to include('secure')
  end

  it 'sends a signed-out visitor to the OpenID Connect sign-in' do
    expect(result['secure']['location']).to end_with('/auth/oidc/start')
  end

  describe 'outside hosted mode (stock)' do
    it 'keeps the framework\'s own session cookie name' do
      get '/settings/profile'

      expect(response.headers['set-cookie'].to_s).not_to include('__Host-')
    end
  end
end
