# frozen_string_literal: true

require 'rails_helper'

# The plan gate and the abuse controls on the paths that cost something: creating
# a submission and sending to a signer (see Extensions::Gate).
describe 'Plan gate and abuse controls' do
  let(:account) { create(:account) }
  let(:author) { create(:user, account:) }
  let(:template) { create(:template, account:, author:) }
  let(:headers) { { 'x-auth-token': author.access_token.token } }
  let(:provider) { Fakes::PlanProvider.new }

  def create_via_api(email: 'john.doe@example.com')
    post '/api/submissions', headers:, params: {
      template_id: template.id, send_email: false,
      submitters: [{ role: 'First Party', email: }]
    }.to_json
  end

  context 'with no plan provider (stock)' do
    it 'creates submissions without any limit' do
      3.times { create_via_api }

      expect(response).to have_http_status(:ok)
      expect(Submission.where(account_id: account.id).count).to eq(3)
    end
  end

  context 'with a plan provider' do
    before do
      Extensions.register(:plan, provider)
      provider.set(account.id, { plan: 'free', status: 'active', features: [], limits: { docs: 2 } })
    end

    it 'answers 402 once the free quota is used, before anything is created' do
      2.times { create_via_api }
      expect(response).to have_http_status(:ok)

      create_via_api

      expect(response).to have_http_status(:payment_required)
      expect(response.parsed_body['error']).to match(/plan limit/i)
      expect(Submission.where(account_id: account.id).count).to eq(2)
    end

    it 'answers 403 for a suspended account' do
      provider.set(account.id, { plan: 'free', status: 'active', features: [], limits: { docs: 10 }, suspended: true })

      create_via_api

      expect(response).to have_http_status(:forbidden)
      expect(Submission.count).to eq(0)
    end

    it 'answers 503 when the plan service has been down past the stale age' do
      provider.fail_with = StandardError.new('down')

      create_via_api

      expect(response).to have_http_status(:service_unavailable)
      expect(Submission.count).to eq(0)
    end

    it 'refuses the send-again buttons for a suspended account' do
      submission = create(:submission, :with_submitters, template:, created_by_user: author)
      provider.set(account.id, { plan: 'free', status: 'suspended', features: [], limits: {} })
      Extensions::PlanCache.clear!
      sign_in(author)

      expect do
        post submitter_send_email_index_path(submission.submitters.first.id)
      end.not_to change(SubmissionEvent, :count)

      expect(response).to redirect_to(root_path)
      expect(SendSubmitterInvitationEmailJob.jobs).to be_empty
    end

    it 'applies the quota to submissions started from a share link by a signer' do
      template.update!(shared_link: true)
      provider.set(account.id, { plan: 'free', status: 'active', features: [], limits: { docs: 1 } })

      2.times do |i|
        put start_form_path(template.slug), params: { submitter: { email: "y#{i}@example.test", name: 'Y' } }
      end

      expect(Submission.where(account_id: account.id).count).to eq(1)
      expect(flash[:alert]).to match(/plan limit/i)
    end

    it 'shows the plan and the usage on the plan page' do
      provider.set(account.id, { plan: 'starter', title: 'Starter', status: 'active', features: [],
                                 limits: { docs: 5, users: nil } })
      create(:submission, template:, created_by_user: author)
      sign_in(author)

      get settings_subscriptions_path

      expect(response.body).to include('Starter')
      expect(response.body).to include('1 / 5')
      expect(response.body).to include('Unlimited')
    end
  end

  describe 'per-account and per-IP rate limits' do
    around do |example|
      with_env('ABUSE_CONTROLS' => 'true', 'RATE_LIMIT_ACCOUNT' => '2', 'RATE_LIMIT_IP' => '100') { example.run }
    end

    it 'answers 429 to an account that creates submissions too fast' do
      2.times { create_via_api }
      expect(response).to have_http_status(:ok)

      create_via_api

      expect(response).to have_http_status(:too_many_requests)
      expect(Submission.where(account_id: account.id).count).to eq(2)
    end

    it 'answers 429 to an address that goes over, across accounts' do
      with_env('RATE_LIMIT_ACCOUNT' => '100', 'RATE_LIMIT_IP' => '2') do
        other_user = create(:user)
        other_template = create(:template, account: other_user.account, author: other_user)
        send_for = lambda do |user, tpl|
          post '/api/submissions', headers: { 'x-auth-token': user.access_token.token }, params: {
            template_id: tpl.id, send_email: false, submitters: [{ role: 'First Party', email: 'a@example.test' }]
          }.to_json
        end

        send_for.call(author, template)
        send_for.call(other_user, other_template)
        send_for.call(author, template)

        expect(response).to have_http_status(:too_many_requests)
      end
    end

    it 'applies to the signer-facing share link too' do
      template.update!(shared_link: true)

      3.times do |i|
        put start_form_path(template.slug), params: { submitter: { email: "x#{i}@example.test", name: 'X' } }
      end

      expect(response).to have_http_status(:found)
      expect(flash[:alert]).to eq('Too many requests')
      expect(Submission.where(account_id: account.id).count).to eq(2)
    end

    it 'does nothing in stock mode' do
      with_env('ABUSE_CONTROLS' => nil) do
        4.times { create_via_api }

        expect(response).to have_http_status(:ok)
      end
    end
  end
end
