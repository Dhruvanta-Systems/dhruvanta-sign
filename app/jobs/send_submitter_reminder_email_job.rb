# frozen_string_literal: true

class SendSubmitterReminderEmailJob
  include Sidekiq::Job

  MAX_REMINDERS = 5

  def perform(params = {})
    submitter = Submitter.find_by(id: params['submitter_id'])
    return unless submitter
    return if submitter.completed_at? || submitter.declined_at?
    return if submitter.submission.archived_at? || submitter.submission.expired?
    return if submitter.preferences['send_email'] == false

    reminder_count = submitter.submission_events.where(event_type: 'send_reminder_email').count
    return if reminder_count >= MAX_REMINDERS

    SubmitterMailer.invitation_email(submitter).deliver_later!
    SubmissionEvent.create!(submitter:, submission: submitter.submission, event_type: 'send_reminder_email',
                            data: { reminder_number: reminder_count + 1 })
  end
end
