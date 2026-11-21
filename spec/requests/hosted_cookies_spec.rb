# frozen_string_literal: true

require 'rails_helper'

# In hosted mode the state cookie and the session cookie carry the __Host- prefix
# (Secure, Path=/, no Domain). The session store is configured at boot, so these
# specs boot a hosted app in a separate process and read its response headers.
describe 'Hosted cookies' do
  def request_in_hosted_process(extra_env = {})
    script = <<~RUBY
      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.https!
      session.get '/sso/start'
      start = { status: session.response.status, cookies: Array(session.response.headers['set-cookie']).join("\\n"),
                location: session.response.headers['location'] }
      session.get '/settings/profile' # not signed in: the redirect keeps the return path in the session
      home = { status: session.response.status, cookies: Array(session.response.headers['set-cookie']).join("\\n") }
      session.delete '/sso/sign_out'
      out = { status: session.response.status, location: session.response.headers['location'] }
      puts "RESULT:" + JSON.generate(start:, home:, sign_out: out)
    RUBY

    run_in_hosted_process(script, extra_env)
  end

  def cookie_lines(text)
    text.split("\n").map(&:strip).compact_blank
  end

  let(:result) { @result ||= request_in_hosted_process }

  it 'names the state cookie __Host-sso_state: Secure, Path=/, no Domain, HttpOnly, SameSite=Lax' do
    line = cookie_lines(result['start']['cookies']).find { |c| c.start_with?('__Host-sso_state=') }

    expect(line).to be_present
    attributes = line.downcase.split(';').map(&:strip)
    expect(attributes).to include('secure', 'path=/', 'httponly', 'samesite=lax')
    expect(attributes.grep(/\Adomain=/)).to be_empty
  end

  it 'sets no state cookie under the unprefixed name' do
    expect(cookie_lines(result['start']['cookies']).grep(/\Asso_state=/)).to be_empty
  end

  it 'names the session cookie with the __Host- prefix: Secure, Path=/, no Domain, SameSite=Lax' do
    line = cookie_lines(result['home']['cookies']).find { |c| c.start_with?('__Host-') && c.include?('session') }

    expect(line).to be_present
    attributes = line.downcase.split(';').map(&:strip)
    expect(attributes).to include('secure', 'path=/', 'httponly', 'samesite=lax')
    expect(attributes.grep(/\Adomain=/)).to be_empty
  end

  it 'sets no unprefixed session cookie' do
    names = cookie_lines(result['home']['cookies'] + "\n#{result['start']['cookies']}").map { |c| c.split('=').first }

    expect(names.reject { |name| name.start_with?('__Host-') }).to be_empty
  end

  it 'delivers the state after the # of the login URL in hosted mode' do
    location = URI.parse(result['start']['location'])

    expect(location.query).to be_nil
    expect(Rack::Utils.parse_query(location.fragment)).to include('state', 'redirect_uri')
  end

  it 'sends sign-out to the identity front when JWT_SSO_SIGNED_OUT_URL is set' do
    signed_out = request_in_hosted_process('JWT_SSO_SIGNED_OUT_URL' => 'https://account.example.test/signed-out')

    expect(signed_out['sign_out']['location']).to eq('https://account.example.test/signed-out')
  end

  describe 'outside hosted mode (stock)' do
    it 'keeps the unprefixed state cookie and the query-string state' do
      with_env('JWT_SSO_ISSUER' => 'https://idp.example.test', 'JWT_SSO_JWKS_URL' => 'https://idp.example.test/jwks',
               'JWT_SSO_AUDIENCE' => 'sign-app', 'JWT_SSO_LOGIN_URL' => 'https://idp.example.test/login') do
        get '/sso/start'

        expect(response.headers['set-cookie']).to include('sso_state=')
        expect(response.headers['set-cookie']).not_to include('__Host-')
        expect(URI.parse(response.location).query).to include('state=')
      end
    end
  end
end
