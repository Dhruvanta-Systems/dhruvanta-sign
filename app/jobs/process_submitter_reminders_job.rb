# frozen_string_literal: true

class ProcessSubmitterRemindersJob
  include Sidekiq::Job

  def perform
    Account.active.find_each do |account|
      config = account.account_configs.find_by(key: AccountConfig::SUBMITTER_REMINDERS)
      next unless config&.value.is_a?(Hash) && config.value['enabled']

      days = parse_days(config.value['days'])
      next if days.blank?

      days.each do |day_count|
        cutoff = day_count.days.ago
        submitters = Submitter.where(account_id: account.id, completed_at: nil, declined_at: nil)
                              .where(sent_at: (cutoff - 1.day)..cutoff)
                              .where.not(email: [nil, ''])
                              .joins(:submission).where(submissions: { archived_at: nil })
                              .where('submissions.expire_at IS NULL OR submissions.expire_at > ?', Time.current)
        submitters.find_each do |submitter|
          next if submitter.preferences['send_email'] == false

          SendSubmitterReminderEmailJob.perform_async('submitter_id' => submitter.id)
        end
      end
    end
  end

  private

  def parse_days(days_string)
    return [] if days_string.blank?

    days_string.to_s.split(',').filter_map { |d| d.strip.to_i.positive? ? d.strip.to_i : nil }.uniq.sort
  end
end
