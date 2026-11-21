# frozen_string_literal: true

# A teammate invitation for sign-in through an external identity provider
# (AUTH_MODE=external): an admin names an email and a role; when that email signs
# in with a verified address the person joins the inviting account. Single use and
# expiring.
class CreateAccountInvitations < ActiveRecord::Migration[8.1]
  def change
    create_table :account_invitations do |t|
      t.references :account, null: false, foreign_key: true
      t.references :invited_by_user, null: true, foreign_key: { to_table: :users }
      t.string :email, null: false
      t.string :role, null: false
      t.datetime :expires_at, null: false
      t.datetime :accepted_at
      t.bigint :accepted_user_id
      t.timestamps
    end

    add_index :account_invitations, :email, unique: true, where: 'accepted_at IS NULL',
                                            name: 'index_account_invitations_on_email_pending'
  end
end
