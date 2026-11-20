# frozen_string_literal: true

class CreateApprovalChains < ActiveRecord::Migration[8.1]
  def change
    create_table :approval_steps do |t|
      t.references :submission, null: false, foreign_key: true
      t.bigint :account_id, null: false
      t.bigint :approver_id, null: false
      t.integer :step_order, null: false, default: 0
      t.string :status, null: false, default: 'pending'
      t.text :comment
      t.datetime :acted_at
      t.timestamps
    end
    add_index :approval_steps, :account_id
    add_index :approval_steps, %i[submission_id step_order]
    add_foreign_key :approval_steps, :users, column: :approver_id
  end
end
