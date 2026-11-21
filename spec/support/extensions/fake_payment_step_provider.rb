# frozen_string_literal: true

# Reference fake of the payment_step_provider port (a payment field in a form).
#
#   create(submitter, field) -> { session_id:, redirect_or_client_secret: }
#   status(session_id) -> { state: 'paid' | 'pending' | 'failed', amount_minor:, currency: }
module Fakes
  class PaymentStepProvider
    def create(_submitter, _field)
      { session_id: 'fake-payment', redirect_or_client_secret: 'secret' }
    end

    def status(_session_id)
      { state: 'paid', amount_minor: 1000, currency: 'INR' }
    end
  end
end
