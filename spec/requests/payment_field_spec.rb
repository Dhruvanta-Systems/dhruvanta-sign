# frozen_string_literal: true

require 'rails_helper'

# Hosted mode has no built-in payment step. The template builder does not offer a
# payment field without a payment_step_provider, and a submission that carries one
# is refused.
describe 'Payment field without a payment_step_provider' do
  let(:account) { create(:account) }
  let(:author) { create(:user, account:) }
  # The factory template carries a payment field (among every other field type).
  let(:template) { create(:template, account:, author:) }

  def create_via_api
    post '/api/submissions', headers: { 'x-auth-token': author.access_token.token }, params: {
      template_id: template.id, send_email: false, submitters: [{ role: 'First Party', email: 'a@example.test' }]
    }.to_json
  end

  describe 'the template builder' do
    before { sign_in(author) }

    it 'does not offer the payment field' do
      get edit_template_path(template)

      expect(response.body).to include('data-with-payment="false"')
    end

    it 'offers it when a payment_step_provider is configured' do
      Extensions.register(:payment_step, Fakes::PaymentStepProvider.new)

      get edit_template_path(template)

      expect(response.body).to include('data-with-payment="true"')
    end
  end

  context 'when hosted' do
    around { |example| with_env('HOSTED_MODE' => 'true') { example.run } }

    before { use_test_redis! } # hosted rate limits need the shared store

    it 'refuses a submission whose template carries a payment field' do
      template

      create_via_api

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to match(/payment fields are not available/i)
      expect(Submission.count).to eq(0)
    end

    it 'has a payment field in the template it refuses' do
      expect(template.fields.pluck('type')).to include('payment')
    end

    it 'refuses it at the model, whatever creates it' do
      expect { create(:submission, template:, created_by_user: author) }
        .to raise_error(Extensions::FeatureUnavailable)
    end

    it 'accepts it when a payment_step_provider is configured' do
      Extensions.register(:payment_step, Fakes::PaymentStepProvider.new)

      expect { create(:submission, template:, created_by_user: author) }.not_to raise_error
    end

    it 'does not refuse a template without a payment field' do
      plain = create(:template, account:, author:, except_field_types: %w[payment])

      expect { create(:submission, template: plain, created_by_user: author) }.not_to raise_error
    end
  end

  context 'when not hosted (stock)' do
    it 'leaves the upstream behaviour alone' do
      expect { create(:submission, template:, created_by_user: author) }.not_to raise_error
    end
  end
end
