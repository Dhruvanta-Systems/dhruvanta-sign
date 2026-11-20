# frozen_string_literal: true

require 'rails_helper'

# Coverage for the security-related headers and routes:
#
# - live `/setup`, `/sign_in` and other GETs emit a strict
#   `Content-Security-Policy` header (default policy initializer:
#   `config/initializers/content_security_policy.rb`)
# - invalid signer URLs `/d/<unknown>` and `/s/<unknown>` return a clean 404
#   instead of soft-redirecting to `/setup`
describe 'Security-related response headers and routes' do
  describe 'Content-Security-Policy' do
    it 'emits a CSP header on the setup wizard before any admin exists' do
      get '/setup'

      expect(response).to have_http_status(:ok)
      csp = response.headers['Content-Security-Policy']
      expect(csp).to be_present
      expect(csp).to include("default-src 'self'")
      expect(csp).to include("frame-ancestors 'self'")
      expect(csp).to include("form-action 'self'")
      expect(csp).to include("base-uri 'self'")
      expect(csp).to include("object-src 'none'")
      expect(csp).to include('upgrade-insecure-requests')
    end

    it 'emits a CSP header on the Devise sign-in page' do
      # Create a user so `maybe_redirect_to_setup` does not redirect
      # the request away from `SessionsController` before the CSP
      # header is observed.
      create(:user, account: create(:account))

      get '/sign_in'

      expect(response).to have_http_status(:ok)
      csp = response.headers['Content-Security-Policy']
      expect(csp).to be_present
      expect(csp).to include("default-src 'self'")
    end

    it 'restricts img-src to self/data/blob (no http/https remote origins)' do
      get '/setup'

      csp = response.headers['Content-Security-Policy']
      expect(csp).to be_present
      expect(csp).to match(/img-src [^;]*'self'/)
      expect(csp).to match(/img-src [^;]*data:/)
      expect(csp).to match(/img-src [^;]*blob:/)
      img_src_directive = csp.split(';').find { |d| d.strip.start_with?('img-src') }
      expect(img_src_directive).not_to include('http:')
      expect(img_src_directive).not_to include('https:')
    end

    it 'allows wss: for Action Cable connections' do
      get '/setup'

      csp = response.headers['Content-Security-Policy']
      connect_src = csp.split(';').find { |d| d.strip.start_with?('connect-src') }
      expect(connect_src).to include('wss:')
    end
  end

  describe 'signer URL 404 behaviour' do
    # In the test environment, `config.action_dispatch.show_exceptions
    # = :none` (see `config/environments/test.rb`), so a controller
    # `find_by!` miss raises `ActiveRecord::RecordNotFound` rather than
    # being rendered as a 404 by `ErrorsController`. The behaviour we
    # care about is that the signer controllers DO NOT silently
    # redirect to `/setup` when no admin user exists — the production
    # `ErrorsController` then translates the bubbled exception to a
    # branded 404.

    it 'raises RecordNotFound (not a /setup redirect) for an unknown /d/<slug>' do
      expect do
        get '/d/no-such-template-12345', headers: { 'Accept' => 'text/html' }
      end.to raise_error(ActiveRecord::RecordNotFound)
    end

    it 'raises RecordNotFound (not a /setup redirect) for an unknown /s/<slug>' do
      expect do
        get '/s/no-such-submitter-12345', headers: { 'Accept' => 'text/html' }
      end.to raise_error(ActiveRecord::RecordNotFound)
    end

    it 'still redirects authenticated dashboard requests to /setup before initial setup' do
      # Sanity: confirm `maybe_redirect_to_setup` still fires for
      # operator surfaces. We only skipped it for the two signer
      # controllers.
      get '/'

      expect(response).to redirect_to(setup_index_path)
    end
  end
end
