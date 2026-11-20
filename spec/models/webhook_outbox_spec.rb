# frozen_string_literal: true

require 'rails_helper'

RSpec.describe WebhookOutbox do
  describe 'validations' do
    it 'rejects an unknown event_type' do
      row = described_class.new(
        target_aud: WebhookOutbox::TARGET_DEFAULT,
        event_type: 'bogus_event',
        payload: '{}',
        delivery_id: SecureRandom.uuid,
        status: WebhookOutbox::STATUS_PENDING
      )
      expect(row).not_to be_valid
      expect(row.errors[:event_type]).to be_present
    end

    it 'accepts the three locked event_types' do
      WebhookOutbox::EVENT_TYPES.each do |evt|
        row = described_class.new(
          target_aud: WebhookOutbox::TARGET_DEFAULT,
          event_type: evt,
          payload: '{}',
          delivery_id: SecureRandom.uuid,
          status: WebhookOutbox::STATUS_PENDING
        )
        expect(row).to be_valid, "expected #{evt} to be a valid event_type"
      end
    end

    it 'rejects duplicate delivery_id' do
      delivery_id = SecureRandom.uuid
      described_class.create!(
        target_aud: WebhookOutbox::TARGET_DEFAULT,
        event_type: WebhookOutbox::EVENT_SUBMISSION_CREATED,
        payload: '{}',
        delivery_id: delivery_id,
        status: WebhookOutbox::STATUS_PENDING
      )
      duplicate = described_class.new(
        target_aud: WebhookOutbox::TARGET_DEFAULT,
        event_type: WebhookOutbox::EVENT_SUBMITTER_SIGNED,
        payload: '{}',
        delivery_id: delivery_id,
        status: WebhookOutbox::STATUS_PENDING
      )
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:delivery_id]).to be_present
    end
  end

  describe 'status helpers' do
    let(:row) do
      described_class.create!(
        target_aud: WebhookOutbox::TARGET_DEFAULT,
        event_type: WebhookOutbox::EVENT_SUBMISSION_CREATED,
        payload: '{}',
        delivery_id: SecureRandom.uuid,
        status: WebhookOutbox::STATUS_PENDING
      )
    end

    it 'reports pending? / sent? / failed?' do
      expect(row).to be_pending
      row.update!(status: WebhookOutbox::STATUS_SENT)
      expect(row).to be_sent
      row.update!(status: WebhookOutbox::STATUS_FAILED)
      expect(row).to be_failed
    end
  end
end
