# frozen_string_literal: true

class CreateSubscriptions < ActiveRecord::Migration[7.1]
  def change
    create_table :subscriptions do |t|
      t.references :account, null: false, foreign_key: true
      t.string :plan, null: false, default: 'free'
      t.string :status, null: false, default: 'active'
      t.string :provider
      t.string :provider_subscription_id
      t.datetime :current_period_start
      t.datetime :current_period_end
      t.datetime :cancelled_at
      t.timestamps
    end
    add_index :subscriptions, :provider_subscription_id, unique: true
    add_index :subscriptions, %i[account_id status]
  end
end
