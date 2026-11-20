# frozen_string_literal: true

# Outbox table for the outbound webhook pipeline (see
# `Outbound::WebhooksDispatcher` and `Outbound::WebhookOutboxDrainWorker`).
#
# Distinct from the per-account `webhook_events` / `webhook_attempts` /
# `webhook_urls` tables (the user-facing webhook surface with per-account URLs
# and secrets and a `sha256=<hex>` signature header): this table feeds a single
# operator-configured receiver.
#
# Outbox semantics:
#   1. `Outbound::WebhooksDispatcher.enqueue` writes a row with status='pending'.
#      The `delivery_id` UNIQUE constraint is the idempotency anchor: callers
#      derive it deterministically from the domain id, so a re-call for the same
#      entity never duplicates an emit.
#   2. `Outbound::WebhookOutboxDrainWorker` drains up to 50 pending rows per
#      Sidekiq tick, re-scheduling itself with `perform_in`.
#   3. Each row is POSTed with `Content-Type: application/json; charset=UTF-8`,
#      `X-Webhook-Signature: <lowercase hmac-sha256 hex, no prefix>` and
#      `X-Webhook-Delivery-Id: <delivery_id>`.
#   4. On 2xx: status='sent', sent_at=now().
#   5. On a non-retryable 4xx (not 429): status='failed' immediately.
#   6. On 5xx, 429 or a network error: attempts++, last_error set;
#      status='failed' after attempts >= 3.
class CreateWebhookOutbox < ActiveRecord::Migration[7.1]
  def change
    # Backend-agnostic shape: DocuSeal can run on Postgres, MySQL/Trilogy or
    # SQLite. A uuid primary key is only portable on Postgres with `pgcrypto`, so
    # the primary key stays a bigint and the meaningful UUID is `delivery_id`
    # (the dedupe anchor, sent in the `X-Webhook-Delivery-Id` header). `id` never
    # leaves the database.
    create_table :webhook_outbox do |t|
      t.string  :target_aud,     null: false, limit: 64
      t.string  :event_type,     null: false, limit: 64
      t.text    :payload,        null: false
      # `string` (length 36) is the lowest-common-denominator UUID
      # representation across PG / MySQL / SQLite.
      t.string  :delivery_id,    null: false, limit: 36
      t.string  :status,         null: false, limit: 16, default: 'pending'
      t.integer :attempts,       null: false, default: 0
      t.text    :last_error
      t.datetime :last_attempt_at
      t.datetime :sent_at
      t.datetime :created_at, null: false
    end

    add_index :webhook_outbox, :delivery_id, unique: true,
                                             name: 'webhook_outbox_delivery_id_unique'
    add_index :webhook_outbox, %i[status last_attempt_at],
              name: 'webhook_outbox_pending_idx'
    add_index :webhook_outbox, %i[target_aud created_at],
              order: { created_at: :desc },
              name: 'webhook_outbox_target_aud_idx'

    # Closed CHECK on status: pending, sent and failed are the only legal states.
    # Postgres only — MySQL/SQLite enforce the whitelist via the
    # model-level `WebhookOutbox::STATUSES` validator.
    return unless /postg/i.match?(connection.adapter_name)

    execute <<~SQL.squish
      ALTER TABLE webhook_outbox
        ADD CONSTRAINT webhook_outbox_status_chk
        CHECK (status IN ('pending', 'sent', 'failed'))
    SQL
  end
end
