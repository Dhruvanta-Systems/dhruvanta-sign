# frozen_string_literal: true

class Subscription < ApplicationRecord
  belongs_to :account

  scope :active, -> { where(status: 'active') }

  def active? = status == 'active'
  def cancelled? = status == 'cancelled'
  def past_due? = status == 'past_due'
end
