# frozen_string_literal: true

module Extensions
  # How much of a countable resource an account has used, for quota checks.
  # Monthly counters cover the current calendar month in UTC.
  module Usage
    SEND_EVENTS = %w[send_email send_sms send_reminder_email].freeze

    module_function

    def count(account, key)
      account_id = account.respond_to?(:id) ? account.id : account

      case key.to_sym
      when :docs then Submission.where(account_id:, created_at: month_range).count
      when :sends then SubmissionEvent.where(account_id:, event_type: SEND_EVENTS, created_at: month_range).count
      when :users then User.where(account_id:, archived_at: nil).count
      when :templates then Template.where(account_id:, archived_at: nil).count
      else 0
      end
    end

    def month_range
      now = Time.now.utc

      now.all_month
    end
  end
end
