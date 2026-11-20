# frozen_string_literal: true

class ApprovalStep < ApplicationRecord
  belongs_to :submission
  belongs_to :approver, class_name: 'User'
  belongs_to :account
  scope :pending, -> { where(status: 'pending') }
  scope :approved, -> { where(status: 'approved') }
  scope :rejected, -> { where(status: 'rejected') }

  def approve!(comment: nil)
    update!(status: 'approved', comment:, acted_at: Time.current)
  end

  def reject!(comment: nil)
    update!(status: 'rejected', comment:, acted_at: Time.current)
  end
end
