# frozen_string_literal: true

# Reference fake of the event_sink port.
#
#   emit(event, payload)
#
# Events: submitter.completed, submission.created, submission.completed,
# submission.declined, template.created, user.created. A sink must be quick and
# must not depend on the request; the app ignores its errors.
module Fakes
  class EventSink
    attr_reader :events

    def initialize
      @events = []
    end

    def emit(event, payload)
      @events << [event, payload]
    end

    def names
      @events.map(&:first)
    end
  end
end
