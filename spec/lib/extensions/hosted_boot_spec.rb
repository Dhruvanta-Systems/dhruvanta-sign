# frozen_string_literal: true

require 'rails_helper'

# HOSTED_MODE=true refuses to boot unless every rule holds. Each rule is tested by
# planting its violation in otherwise valid inputs.
describe Extensions::HostedBoot do
  def route(controller, action)
    instance_double(ActionDispatch::Journey::Route, defaults: { controller:, action: })
  end

  let(:good_routes) { [route('dashboard', 'index'), route('oidc', 'start')] }

  let(:valid) do
    { env: {}, routes: good_routes, delivery_method: :extension_notifier, smtp_settings: nil,
      storage_name: :aws_s3, configured: ->(_port) { true } }
  end

  def violations(**overrides)
    described_class.violations(**valid, **overrides)
  end

  it 'passes when everything is in place' do
    expect(violations).to be_empty
  end

  it 'reports a missing port' do
    found = violations(configured: ->(port) { port != :otp })

    expect(found).to contain_exactly('missing extensions: otp')
  end

  it 'reports every required port that is missing' do
    found = violations(configured: ->(_port) { false })

    expect(found.first).to eq('missing extensions: notifier, otp, plan, storage')
  end

  %w[sessions passwords invitations setup mfa_setup users_send_reset_password jwt_sso_handoff].each do |controller|
    it "reports a drawn #{controller} route" do
      found = violations(routes: good_routes + [route(controller, 'show')])

      expect(found.join).to include('local auth routes are drawn', "#{controller}#show")
    end
  end

  %w[new create].each do |action|
    it "reports a drawn local user #{action} route" do
      found = violations(routes: good_routes + [route('users', action)])

      expect(found.join).to include("users##{action}")
    end
  end

  it 'does not mind the users routes that only edit or remove' do
    expect(violations(routes: good_routes + [route('users', 'update'), route('users', 'destroy')])).to be_empty
  end

  it 'reports the profile password change route' do
    found = violations(routes: good_routes + [route('profile', 'update_password')])

    expect(found.join).to include('profile#update_password')
  end

  it 'reports OpenID Connect that is not configured' do
    expect(violations(oidc_enabled: false).join).to include('OpenID Connect is not configured')
  end

  it 'reports a client secret file that cannot be read' do
    found = violations(oidc_secret_error: 'the client secret file /nope is not readable')

    expect(found).to contain_exactly('the client secret file /nope is not readable')
  end

  it 'reports the removed custom JWT handoff settings' do
    found = violations(env: { 'JWT_SSO_ISSUER' => 'https://op.example.com' })

    expect(found.join).to include('custom JWT handoff was removed').and include('JWT_SSO_ISSUER')
  end

  it 'reports SMTP configured by SMTP_ADDRESS' do
    expect(violations(env: { 'SMTP_ADDRESS' => 'smtp.example.test' }).join).to include('SMTP delivery is configured')
  end

  it 'reports SMTP settings and the smtp delivery method' do
    expect(violations(smtp_settings: { address: 'smtp.example.test' }).join).to include('SMTP delivery is configured')
    expect(violations(delivery_method: :smtp).join).to include('SMTP delivery is configured')
  end

  it 'reports a mail delivery method that is not the notifier' do
    expect(violations(delivery_method: :test).join).to include('expected the notifier')
  end

  it 'reports disk storage' do
    expect(violations(storage_name: :disk).join).to include('storage is :disk')
    expect(violations(storage_name: 'disk').join).to include('storage is :disk')
  end

  describe '.verify!', :oidc do
    def register_ports
      %i[notifier otp plan].each { |port| Extensions.register(port, Object.new) }
      Extensions.register(:storage, Fakes::StorageService.new(:aws_s3))
      allow(ActionMailer::Base).to receive(:delivery_method).and_return(:extension_notifier)
    end

    it 'aborts on the stock app: it draws local auth routes and has no extensions' do
      with_env('HOSTED_MODE' => 'true') do
        expect { described_class.verify! }.to raise_error(described_class::Error, /HOSTED_MODE refuses to start/)
      end
    end

    it 'names the violations in the abort message' do
      with_env('HOSTED_MODE' => 'true') do
        expect { described_class.verify! }.to raise_error(described_class::Error) { |error|
          expect(error.message).to include('missing extensions', 'local auth routes are drawn', 'OpenID Connect is not configured')
        }
      end
    end

    it 'passes with every port registered, OIDC configured, external auth, notifier mail and an object store' do
      register_ports

      with_routes_for(oidc_env('AUTH_MODE' => 'external', 'HOSTED_MODE' => 'true')) do
        expect(described_class.verify!).to be(true)
      end
    end

    it 'aborts when the client secret file cannot be read' do
      register_ports

      with_routes_for(oidc_env('AUTH_MODE' => 'external', 'HOSTED_MODE' => 'true',
                               'OIDC_CLIENT_SECRET_FILE' => '/nonexistent/secret')) do
        expect { described_class.verify! }.to raise_error(described_class::Error, /not readable/)
      end
    end

    it 'aborts when the client secret file is empty' do
      register_ports
      empty = Tempfile.new('empty-secret')

      with_routes_for(oidc_env('AUTH_MODE' => 'external', 'HOSTED_MODE' => 'true', 'OIDC_CLIENT_SECRET_FILE' => empty.path)) do
        expect { described_class.verify! }.to raise_error(described_class::Error, /is empty/)
      end
    end

    it 'aborts when SMTP is configured even though everything else is in place' do
      register_ports

      with_routes_for(oidc_env('AUTH_MODE' => 'external', 'HOSTED_MODE' => 'true', 'SMTP_ADDRESS' => 'smtp.example.test')) do
        expect { described_class.verify! }.to raise_error(described_class::Error, /SMTP delivery is configured/)
      end
    end

    it 'aborts when the removed JWT handoff is still configured' do
      register_ports

      with_routes_for(oidc_env('AUTH_MODE' => 'external', 'HOSTED_MODE' => 'true', 'JWT_SSO_ISSUER' => 'https://op.example.com')) do
        expect { described_class.verify! }.to raise_error(described_class::Error, /custom JWT handoff was removed/)
      end
    end
  end

  describe 'the boot hook' do
    it 'is wired: the initializer runs verify! after initialization in hosted mode' do
      source = Rails.root.join('config/initializers/extensions.rb').read

      expect(source).to include('if Extensions.hosted?', 'Extensions::HostedBoot.verify!')
    end

    it 'really aborts a boot in hosted mode (a separate process)' do
      env = { 'HOSTED_MODE' => 'true', 'RAILS_ENV' => 'test' }
      output, status = Open3.capture2e(env, 'bin/rails', 'runner', '1', chdir: Rails.root.to_s)

      expect(status).not_to be_success
      expect(output).to include('HOSTED_MODE refuses to start')
    end
  end
end
