# frozen_string_literal: true

Rails.application.config.after_initialize do
  next if Rails.env.test? || Docuseal.multitenant?

  Thread.new do
    loop do
      sleep 1.hour.to_i
      ProcessSubmitterRemindersJob.perform_async
      ProcessDocumentExpiryCheckJob.perform_async if Time.current.hour == 9
    rescue StandardError => e
      Rails.logger.error("Scheduler error: #{e.message}")
    end
  end
end
