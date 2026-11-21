# frozen_string_literal: true

# Server-side registry of sign-ins made through the OpenID Connect provider. The
# browser holds only a random token; a row that is revoked (sign-out, back-channel
# logout) or past its expiry ends the session on the next request.
class CreateOidcSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :oidc_sessions do |t|
      t.references :user, null: false, foreign_key: true
      t.string :issuer, null: false
      t.string :sub, null: false
      t.string :sid
      t.string :token_digest, null: false
      t.datetime :auth_time
      t.string :acr
      t.string :amr, array: true, default: [], null: false
      t.datetime :expires_at, null: false
      t.datetime :revoked_at
      t.timestamps
    end

    add_index :oidc_sessions, :token_digest, unique: true
    add_index :oidc_sessions, %i[issuer sid]
    add_index :oidc_sessions, %i[issuer sub]

    create_table :oidc_logout_tokens do |t|
      t.string :issuer, null: false
      t.string :jti, null: false
      t.datetime :expires_at, null: false
      t.datetime :created_at, null: false
    end

    add_index :oidc_logout_tokens, %i[issuer jti], unique: true
    add_index :oidc_logout_tokens, :expires_at
  end
end
