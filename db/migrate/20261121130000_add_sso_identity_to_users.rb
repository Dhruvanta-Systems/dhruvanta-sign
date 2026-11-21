# frozen_string_literal: true

# The stable identity of a person at the external identity provider: the issuer and
# the subject. Sign-in finds the user by this pair; an email address is only ever
# used to bind an invitation or to link a user that has no identity yet.
class AddSsoIdentityToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :sso_issuer, :string
    add_column :users, :sso_subject, :string

    add_index :users, %i[sso_issuer sso_subject], unique: true, where: 'sso_subject IS NOT NULL',
                                                  name: 'index_users_on_sso_identity'
  end
end
