# frozen_string_literal: true

require 'rails_helper'

describe 'Identity verification API' do
  let(:account) { create(:account) }
  let(:author) { create(:user, account:) }
  let(:template) { create(:template, account:, author:, only_field_types: %w[text]) }
  let(:submission) { create(:submission, template:, created_by_user: author) }
  let(:submitter) do
    create(:submitter, submission:, uuid: submission.template_submitters.first['uuid'],
                       values: { 'existing-field' => 'preserved' })
  end

  it 'keeps signer identity-verification start explicitly disabled' do
    put '/api/identity_verification/verification-field', params: {
      submitter_slug: 'submitter-slug',
      redirect_url: 'https://example.test/s/submitter-slug'
    }, as: :json

    expect(response).to have_http_status(:service_unavailable)
    expect(response.headers['Cache-Control']).to include('no-store')
    expect(response.parsed_body).to include(
      'field_uuid' => 'verification-field',
      'available_methods' => [],
      'verification_available' => false,
      'disabled_reason' => 'public_identity_verification_backend_missing'
    )
    expect(response.parsed_body['error']).to include('Identity verification is not available')
  end

  it 'keeps signer identity-verification completion explicitly unverified' do
    post '/api/identity_verification', params: {
      submitter_slug: 'submitter-slug'
    }, as: :json

    expect(response).to have_http_status(:not_found)
    expect(response.headers['Cache-Control']).to include('no-store')
    expect(response.parsed_body).to include(
      'completed' => false,
      'available_methods' => [],
      'verification_available' => false,
      'disabled_reason' => 'public_identity_verification_backend_missing'
    )
    expect(response.parsed_body['error']).to include('Identity verification is not available')
  end

  it 'keeps signer identity-verification provider callbacks explicitly disabled' do
    post '/api/identity_verification/callbacks/eideasy', params: {
      doc_id: 'provider-document-id',
      status: 'completed'
    }, as: :json

    expect(response).to have_http_status(:service_unavailable)
    expect(response.headers['Cache-Control']).to include('no-store')
    expect(response.parsed_body).to include(
      'callback_accepted' => false,
      'provider' => 'eideasy',
      'available_methods' => [],
      'verification_available' => false,
      'disabled_reason' => 'public_identity_verification_backend_missing'
    )
    expect(response.parsed_body['error']).to include('Identity verification is not available')
  end

  it 'logs disabled callback attempts without raw source IP or provider document IDs' do
    allow(Rails.logger).to receive(:info)

    post '/api/identity_verification/callbacks/eideasy', params: {
      submitter_slug: 'submitter-slug',
      doc_id: 'provider-document-id',
      status: 'completed'
    }, headers: {
      'REMOTE_ADDR' => '203.0.113.42'
    }, as: :json

    expect(response).to have_http_status(:service_unavailable)
    expect(Rails.logger).to have_received(:info).with(satisfy do |message|
      next false unless message.is_a?(String) && message.start_with?('{')

      begin
        payload = JSON.parse(message)
      rescue JSON::ParserError
        next false
      end

      payload['event'] == 'identity_verification.disabled' &&
        payload['action'] == 'callback' &&
        payload['provider'] == 'eideasy' &&
        payload['source_ip_hash'].match?(/\A[0-9a-f]{64}\z/) &&
        !payload.key?('remote_ip') &&
        !payload.key?('doc_id') &&
        !message.include?('203.0.113.42') &&
        !message.include?('provider-document-id')
    end)
  end

  it 'does not mutate signer state or call premium services while disabled' do
    verification_field_uuid = 'verification-field'
    submission.update!(
      template_fields: submission.template_fields + [
        {
          'uuid' => verification_field_uuid,
          'submitter_uuid' => submitter.uuid,
          'name' => 'Identity Verification',
          'type' => 'verification',
          'required' => true,
          'preferences' => {},
          'areas' => []
        }
      ]
    )

    original_values = submitter.reload.values.deep_dup
    original_completed_at = submitter.completed_at
    original_updated_at = submitter.updated_at

    premium_bridge_methods = %i[
      enabled?
      plan_for
      create_checkout
      create_video_kyc_session
      video_kyc_status
    ]
    premium_bridge_methods.each { |method| allow(PremiumBridge).to receive(method) }

    verification_event_count = lambda do
      SubmissionEvent.where(submitter:, event_type: %w[start_verification complete_verification]).count
    end

    expect do
      put "/api/identity_verification/#{verification_field_uuid}", params: {
        submitter_slug: submitter.slug,
        redirect_url: "https://example.test/s/#{submitter.slug}"
      }, as: :json

      post '/api/identity_verification', params: {
        submitter_slug: submitter.slug
      }, as: :json

      post '/api/identity_verification/callbacks/eideasy', params: {
        submitter_slug: submitter.slug,
        doc_id: 'provider-document-id',
        status: 'completed'
      }, as: :json
    end.not_to change(&verification_event_count)

    submitter.reload
    expect(submitter.values).to eq(original_values)
    expect(submitter.completed_at).to eq(original_completed_at)
    expect(submitter.updated_at).to eq(original_updated_at)
    premium_bridge_methods.each { |method| expect(PremiumBridge).not_to have_received(method) }
  end
end
