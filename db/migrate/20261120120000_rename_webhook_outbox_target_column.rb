# frozen_string_literal: true

# Generic name for the receiver a queued webhook is addressed to.
class RenameWebhookOutboxTargetColumn < ActiveRecord::Migration[8.1]
  def change
    rename_column :webhook_outbox, :target_aud, :target
    rename_index :webhook_outbox, 'webhook_outbox_target_aud_idx', 'webhook_outbox_target_idx'
  end
end
