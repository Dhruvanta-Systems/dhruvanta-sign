# frozen_string_literal: true

class ProcessDocumentExpiryCheckJob
  include Sidekiq::Job

  def perform
    Submission.active.where(expire_at: Time.current..7.days.from_now).where.not(expire_at: nil)
              .includes(:submitters, :template, :created_by_user).find_each do |submission|
      next if submission.submitters.all?(&:completed_at?)

      user = submission.created_by_user || submission.template&.author
      next unless user

      begin
        SubmitterMailer.expiry_warning_email(submission, user).deliver_later!
      rescue StandardError
        nil
      end
    end
  end
end
