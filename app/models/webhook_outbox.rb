# frozen_string_literal: true

# == Schema Information
#
# Table name: webhook_outbox
#
#  id              :bigint           not null, primary key
#  target_aud      :string(64)       not null
#  event_type      :string(64)       not null
#  payload         :text             not null
#  delivery_id     :string(36)       not null
#  status          :string(16)       not null, default('pending')
#  attempts        :integer          not null, default(0)
#  last_error      :text
#  last_attempt_at :datetime
#  sent_at         :datetime
#  created_at      :datetime         not null
#
# Indexes
#
#  webhook_outbox_delivery_id_unique  (delivery_id) UNIQUE
#  webhook_outbox_pending_idx         (status, last_attempt_at)
#  webhook_outbox_target_aud_idx      (target_aud, created_at DESC)
#

# Outbound webhook outbox row.
#
# Distinct from `WebhookEvent` / `WebhookAttempt` / `WebhookUrl`, which serve the
# per-account, user-configured webhook surface. This table holds events for a
# single operator-configured receiver (WEBHOOK_OUTBOX_URL), delivered with a
# bare-hex `X-Webhook-Signature` header instead of the `sha256=<hex>` style used
# for per-account webhooks. See {Outbound::WebhooksDispatcher}.
class WebhookOutbox < ApplicationRecord
  self.table_name = 'webhook_outbox'

  STATUS_PENDING = 'pending'
  STATUS_SENT    = 'sent'
  STATUS_FAILED  = 'failed'
  STATUSES       = [STATUS_PENDING, STATUS_SENT, STATUS_FAILED].freeze

  TARGET_DEFAULT = 'default'

  # Event types emitted to the outbox receiver.
  EVENT_SUBMISSION_CREATED   = 'submission_created'
  EVENT_SUBMISSION_COMPLETED = 'submission_completed'
  EVENT_SUBMITTER_SIGNED     = 'submitter_signed'
  EVENT_TYPES = [
    EVENT_SUBMISSION_CREATED,
    EVENT_SUBMISSION_COMPLETED,
    EVENT_SUBMITTER_SIGNED
  ].freeze

  validates :target_aud, presence: true, length: { maximum: 64 }
  validates :event_type, presence: true,
                         length: { maximum: 64 },
                         inclusion: { in: EVENT_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :delivery_id, presence: true, uniqueness: true
  validates :payload, presence: true
  validates :attempts, numericality: { greater_than_or_equal_to: 0 }

  scope :pending, -> { where(status: STATUS_PENDING) }
  scope :sent,    -> { where(status: STATUS_SENT) }
  scope :failed,  -> { where(status: STATUS_FAILED) }

  before_create :assign_defaults

  def pending?
    status == STATUS_PENDING
  end

  def sent?
    status == STATUS_SENT
  end

  def failed?
    status == STATUS_FAILED
  end

  private

  def assign_defaults
    self.status     ||= STATUS_PENDING
    self.attempts   ||= 0
    self.created_at ||= Time.current
  end
end
