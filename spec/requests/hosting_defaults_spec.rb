# frozen_string_literal: true

require 'rails_helper'

# What a fresh deployment gets by default: no default administrator, no debug
# routes, no cross-origin access, safe cookies, a generated secret, an optional
# setup token and an optional host allow-list.
describe 'Hosting defaults' do
  describe 'default administrator' do
    it 'has none: a fresh database has no users and the app asks to create the first one' do
      expect(User.count).to eq(0)

      get '/'

      expect(response).to redirect_to('/setup')
    end

    it 'seeds no user' do
      seeds = Rails.root.join('db/seeds.rb')

      expect(!seeds.exist? || seeds.read.match?(/User\.|Account\./)).to be(false)
    end
  end

  describe 'first-run setup token' do
    let(:setup_params) do
      { user: { first_name: 'Ada', last_name: 'Admin', email: 'ada@example.com', password: 'a-long-password-1' },
        account: { name: 'Example', timezone: 'UTC' },
        encrypted_config: { value: 'https://sign.example.test' } }
    end

    around do |example|
      original = ENV.fetch('SETUP_TOKEN', nil)
      example.run
    ensure
      original.nil? ? ENV.delete('SETUP_TOKEN') : ENV['SETUP_TOKEN'] = original
    end

    it 'refuses to create the first administrator without the token' do
      ENV['SETUP_TOKEN'] = 'let-me-in-7'

      expect { post '/setup', params: setup_params }.not_to change(User, :count)
      expect(response).to redirect_to('/setup')

      expect { post '/setup', params: setup_params.merge(setup_token: 'wrong') }.not_to change(User, :count)
    end

    it 'shows the token field only when a token is configured' do
      get '/setup'
      expect(response.body).not_to include('setup_token')

      ENV['SETUP_TOKEN'] = 'let-me-in-7'
      get '/setup'
      expect(response.body).to include('setup_token')
    end

    it 'creates the administrator with the right token' do
      ENV['SETUP_TOKEN'] = 'let-me-in-7'

      expect { post '/setup', params: setup_params.merge(setup_token: 'let-me-in-7') }.to change(User, :count).by(1)
    end
  end

  describe 'debug routes' do
    it 'are not mounted outside development' do
      paths = Rails.application.routes.routes.map { |r| r.path.spec.to_s }

      expect(paths.grep(%r{letter_opener|/debug|/rails/info|web-console|/__})).to eq([])
    end
  end

  describe 'cross-origin access' do
    it 'sends no CORS headers to a foreign origin' do
      create(:user)

      ['/sign_in', '/api/user'].each do |path|
        get path, headers: { 'Origin' => 'https://evil.example' }

        expect(response.headers.keys.map(&:downcase)).not_to include('access-control-allow-origin')
      end
    end
  end

  describe 'session cookie' do
    it 'is HttpOnly and SameSite=Lax' do
      user = create(:user, password: 'a-long-password-1')

      post user_session_path, params: { user: { email: user.email, password: 'a-long-password-1' } }

      cookie = Array(response.headers['Set-Cookie']).join("\n").downcase
      expect(cookie).to include('_session')
      expect(cookie).to include('httponly')
      expect(cookie).to include('samesite=lax')
    end
  end

  describe 'secret key base' do
    it 'is generated at first boot, never a built-in default, and the file is mode 0600' do
      source = Rails.root.join('config/dotenv.rb').read

      expect(source).to include('SecureRandom.hex(64)')
      expect(source).to include('File.chmod(0o600')
      expect(Rails.root.join('config/secrets.yml')).not_to exist
    end
  end

  describe ProductionDefaultsCheck do
    it 'warns about each weak setting' do
      expect(described_class.warnings({}).size).to eq(3)
    end

    it 'is quiet when the three settings are made' do
      env = { 'FORCE_SSL' => 'sign.example.test', 'HOST' => 'sign.example.test', 'ALLOWED_HOSTS' => 'sign.example.test' }

      expect(described_class.warnings(env)).to eq([])
    end

    it 'treats FORCE_SSL=false as off' do
      expect(described_class.force_ssl?('FORCE_SSL' => 'false')).to be(false)
    end

    it 'parses the host list' do
      expect(described_class.allowed_hosts('ALLOWED_HOSTS' => ' a.test, ,*.b.test ')).to eq(%w[a.test *.b.test])
    end
  end

  describe 'host allow-list' do
    let(:hosts) { ProductionDefaultsCheck.allowed_hosts('ALLOWED_HOSTS' => 'sign.example.test') }
    let(:app) do
      inner = ->(_env) { [200, { 'content-type' => 'text/plain' }, ['ok']] }
      ActionDispatch::HostAuthorization.new(
        inner, hosts, exclude: ->(request) { request.path == '/up' }
      )
    end

    def status_for(host, path = '/')
      Rack::MockRequest.new(app).get("http://#{host}#{path}").status
    end

    it 'serves the configured host, refuses another, and leaves the health check open' do
      expect(status_for('sign.example.test')).to eq(200)
      expect(status_for('evil.example')).to eq(403)
      expect(status_for('evil.example', '/up')).to eq(200)
    end
  end
end
