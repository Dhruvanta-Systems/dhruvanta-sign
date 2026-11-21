# frozen_string_literal: true

# Reference fake of the otp_provider port.
#
#   send_code(subject:, purpose:, channel:, to:, locale:, account_id:)
#   verify(subject:, code:, purpose:) -> true / false
#
# `subject` identifies what the code is for (an opaque string the app chooses);
# the provider generates the code, delivers it to `to` and later checks it.
module Fakes
  class OtpProvider
    CODE = '123456'

    attr_reader :sent, :verified

    def initialize
      @sent = []
      @verified = []
    end

    def send_code(**params)
      @sent << params
      true
    end

    def verify(subject:, code:, purpose:)
      @verified << { subject:, code:, purpose: }
      code == CODE
    end
  end
end
