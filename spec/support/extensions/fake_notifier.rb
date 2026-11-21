# frozen_string_literal: true

# Reference fake of the notifier port (see Extensions and
# Extensions::NotifierDeliveryMethod).
#
#   deliver(channel:, to:, ...) -> anything
#
# The email channel receives: to, cc, bcc, from, reply_to, subject, html, text,
# template_key ("UserMailer#invitation_email"), vars, account_id, message_id and
# attachments ([{ filename:, content_type:, content:, inline:, content_id: }]).
module Fakes
  class Notifier
    attr_accessor :fail_with
    attr_reader :deliveries

    def initialize
      @deliveries = []
    end

    def deliver(**message)
      raise fail_with if fail_with

      @deliveries << message
      { 'status' => 'queued' }
    end
  end
end
