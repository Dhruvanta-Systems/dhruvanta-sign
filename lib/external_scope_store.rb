# frozen_string_literal: true

# Persists the external tenant and user identifiers learned from a verified
# sign-in so later outbound webhooks can carry them as extra payload fields.
module ExternalScopeStore
  module_function

  def persist!(account:, user:, tenant_id:, external_user_id:)
    return if account.nil? || user.nil?

    ActiveRecord::Base.transaction do
      write_account_scope(account, tenant_id)
      write_user_scope(user, external_user_id)
    end
  end

  # Extra fields merged into outbound webhook payloads. The field names default
  # to `external_tenant_id` / `external_user_id` and can be renamed with
  # WEBHOOK_OUTBOX_TENANT_FIELD and WEBHOOK_OUTBOX_USER_FIELD.
  def scope_for(account:, user:)
    {
      ENV.fetch('WEBHOOK_OUTBOX_TENANT_FIELD', 'external_tenant_id') => tenant_id_for(account),
      ENV.fetch('WEBHOOK_OUTBOX_USER_FIELD', 'external_user_id') => external_user_id_for(user)
    }
  end

  def tenant_id_for(account)
    normalize(account&.account_configs&.find_by(key: AccountConfig::EXTERNAL_TENANT_ID_KEY)&.value)
  end

  def external_user_id_for(user)
    normalize(user&.user_configs&.find_by(key: UserConfig::EXTERNAL_USER_ID_KEY)&.value)
  end

  def write_account_scope(account, tenant_id)
    write_config(account.account_configs, AccountConfig::EXTERNAL_TENANT_ID_KEY, tenant_id)
  end
  private_class_method :write_account_scope

  def write_user_scope(user, external_user_id)
    write_config(user.user_configs, UserConfig::EXTERNAL_USER_ID_KEY, external_user_id)
  end
  private_class_method :write_user_scope

  def write_config(configs, key, value)
    normalized = normalize(value)
    return if normalized.nil?

    config = configs.find_or_initialize_by(key: key)
    config.value = normalized
    config.save!
  end
  private_class_method :write_config

  def normalize(value)
    raw = value.to_s.strip
    raw.empty? ? nil : raw
  end
  private_class_method :normalize
end
