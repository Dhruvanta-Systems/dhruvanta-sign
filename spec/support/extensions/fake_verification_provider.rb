# frozen_string_literal: true

# Reference fake of the verification_provider port (identity / video verification).
#
#   start(payload) -> Hash (a session; { 'error' => ... } to refuse)
#   status(submitter_slug) -> Hash ({ 'status' => 'not_started' | 'completed' | ... })
module Fakes
  class VerificationProvider
    attr_reader :started

    def initialize
      @started = []
    end

    def start(payload)
      @started << payload
      { 'session_id' => 'fake-session', 'status' => 'started' }
    end

    def status(_submitter_slug)
      { 'status' => 'started' }
    end
  end
end
