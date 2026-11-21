# frozen_string_literal: true

class SendSubmitterVerificationEmailJob
  include Sidekiq::Job

  def perform(params = {})
    submitter = Submitter.find(params['submitter_id'])

    locale = params['locale'].presence || submitter.account.locale

    if SignerOtp.provider?
      SignerOtp.send_code([submitter.email.downcase.squish, submitter.slug].join(':'), to: submitter.email,
                                                                                       locale:, account_id: submitter.account_id)
    else
      SubmitterMailer.otp_verification_email(submitter, locale:).deliver_now!
    end

    SubmissionEvent.create!(submitter_id: params['submitter_id'],
                            event_type: 'send_2fa_email',
                            data: { email: submitter.email })
  end
end
