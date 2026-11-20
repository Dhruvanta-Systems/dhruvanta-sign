# frozen_string_literal: true

require 'rails_helper'

# Request coverage for GET /api/admin/audit_events: service-JWT auth, filters, paging and the audit shape.
describe 'API admin audit_events' do
  let(:jwks_url) { 'http://localhost:8081/.well-known/jwks.json' }
  let(:expected_audience) { 'audit.sign.example.test' }
  let(:required_scope) { 'audit.read' }
  let!(:author) { create(:user) }
  let!(:account) { author.account }
  let!(:folder) { create(:template_folder, account:, author:) }
  let!(:template) { create(:template, account:, author:, folder:) }

  before(:all) do
    @ec_key = OpenSSL::PKey::EC.generate('prime256v1')
    @kid    = SecureRandom.uuid
    @jwk    = JWT::JWK.new(@ec_key, kid: @kid, alg: 'ES256', use: 'sig')
  end

  before do
    @memory_cache = ActiveSupport::Cache::MemoryStore.new
    allow(Rails).to receive(:cache).and_return(@memory_cache)

    stub_request(:get, jwks_url).to_return(
      status: 200,
      headers: { 'Content-Type' => 'application/json' },
      body: { keys: [@jwk.export] }.to_json
    )

    # The verifier reads its JWKS URL, audience and scope from the environment;
    # pin them for the duration of each example.
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('SERVICE_JWT_JWKS_URL', anything).and_return(jwks_url)
    allow(ENV).to receive(:fetch).with('SERVICE_JWT_AUDIENCE', anything).and_return(expected_audience)
    allow(ENV).to receive(:fetch).with('SERVICE_JWT_AUDIT_SCOPE', anything).and_return(required_scope)
  end

  def mint(claims_overrides = {}, signing_key: @ec_key, kid: @kid, **extra_claims)
    now = Time.now.utc.to_i
    claims_overrides = claims_overrides.merge(extra_claims)
    claims = {
      iss: 'https://issuer.example.test',
      sub: 'svc-audit-reader',
      aud: expected_audience,
      scopes: required_scope,
      iat: now,
      exp: now + 60,
      jti: SecureRandom.uuid
    }.merge(claims_overrides)

    JWT.encode(claims, signing_key, 'ES256', { kid: kid, typ: 'JWT' })
  end

  def auth_headers(token)
    { 'Authorization' => "Bearer #{token}" }
  end

  describe 'GET /api/admin/audit_events' do
    it 'returns flat audit rows for valid service-client tokens' do
      submission = create(:submission, :with_submitters, template:, created_by_user: author)
      submitter = submission.submitters.first
      create(:submission_event, submission: submission, submitter: submitter,
                                event_type: 'view_form')
      create(:submission_event, submission: submission, submitter: submitter,
                                event_type: 'complete_form')

      token = mint
      get '/api/admin/audit_events', headers: auth_headers(token)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body['totalElements']).to eq(2)
      expect(body['size']).to eq(50) # default size
      expect(body['number']).to eq(0)
      expect(body['content'].size).to eq(2)

      row = body['content'].first
      expect(row).to include(
        'event_code' => start_with('DOCUSEAL_'),
        'target_id_type' => 'DOCUSEAL_SUBMISSION',
        'actor_role' => 'SUBMITTER'
      )
      expect(row['target_id_hash']).to be_present
      expect(row['target_id_hash'].length).to eq(64) # sha256 hex
      expect(row['request_id']).to be_nil
      expect(row['product_aud']).to be_nil
      expect(row['webhook_source']).to be_nil
      expect(row['metadata']).to be_a(Hash)
    end

    it 'returns 401 problem+json when the Authorization header is missing' do
      get '/api/admin/audit_events'

      expect(response).to have_http_status(:unauthorized)
      expect(response.media_type).to eq('application/problem+json')
      expect(response.parsed_body['code']).to eq('service-token-missing')
    end

    it 'returns 403 problem+json when the audience is wrong' do
      token = mint(aud: 'audit.other.example.test')

      get '/api/admin/audit_events', headers: auth_headers(token)

      expect(response).to have_http_status(:forbidden)
      expect(response.media_type).to eq('application/problem+json')
      expect(response.parsed_body['code']).to eq('service-token-wrong-aud')
    end

    it 'returns 403 problem+json when the scopes claim lacks the audit scope' do
      token = mint(scopes: 'template.read submission.read')

      get '/api/admin/audit_events', headers: auth_headers(token)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body['code']).to eq('service-token-insufficient-scope')
    end

    it 'paginates correctly with page+size params' do
      submission = create(:submission, :with_submitters, template:, created_by_user: author)
      submitter = submission.submitters.first
      3.times { create(:submission_event, submission: submission, submitter: submitter) }

      token = mint
      get '/api/admin/audit_events', params: { page: 0, size: 2 },
                                     headers: auth_headers(token)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body['totalElements']).to eq(3)
      expect(body['size']).to eq(2)
      expect(body['number']).to eq(0)
      expect(body['content'].size).to eq(2)

      get '/api/admin/audit_events', params: { page: 1, size: 2 },
                                     headers: auth_headers(token)
      body = response.parsed_body
      expect(body['number']).to eq(1)
      expect(body['content'].size).to eq(1)
    end

    it 'filters by event_type when provided' do
      submission = create(:submission, :with_submitters, template:, created_by_user: author)
      submitter = submission.submitters.first
      create(:submission_event, submission: submission, submitter: submitter,
                                event_type: 'view_form')
      create(:submission_event, submission: submission, submitter: submitter,
                                event_type: 'complete_form')

      token = mint
      get '/api/admin/audit_events', params: { event_type: 'view_form' },
                                     headers: auth_headers(token)

      body = response.parsed_body
      expect(body['totalElements']).to eq(1)
      expect(body['content'].first['event_code']).to eq('DOCUSEAL_VIEW_FORM')
    end

    it 'filters by account_id when provided' do
      submission_a = create(:submission, :with_submitters, template:, created_by_user: author)
      account_b = create(:account)
      author_b = create(:user, account: account_b)
      folder_b = create(:template_folder, account: account_b, author: author_b)
      template_b = create(:template, account: account_b, author: author_b, folder: folder_b)
      submission_b = create(:submission, :with_submitters, template: template_b, created_by_user: author_b)
      submitter_a = submission_a.submitters.first
      submitter_b = submission_b.submitters.first
      ev_a = create(:submission_event, submission: submission_a, submitter: submitter_a)
      _ev_b = create(:submission_event, submission: submission_b, submitter: submitter_b)

      token = mint
      get '/api/admin/audit_events', params: { account_id: ev_a.account_id },
                                     headers: auth_headers(token)

      body = response.parsed_body
      expect(body['totalElements']).to eq(1)
    end
  end
end
