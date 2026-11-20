# frozen_string_literal: true

module Outbound
  module ExternalScope
    module_function

    def for_submission(submission)
      account = submission&.account
      user = requester_for(submission)

      JwtSso::ScopeStore.scope_for(account: account, user: user)
    end

    def requester_for(submission)
      return nil if submission.nil?

      submission.created_by_user ||
        submission.template&.author ||
        submission.account&.users&.admins&.order(:id)&.first ||
        submission.account&.users&.order(:id)&.first
    end
    private_class_method :requester_for
  end
end
