# frozen_string_literal: true

class AnalyticsController < ApplicationController
  before_action :authorize_analytics!
  before_action -> { require_premium_feature!('analytics') }

  def index
    @period = params[:period] || '30'
    days = @period.to_i.days.ago
    submitters = current_account.submitters.where(created_at: days..)
    @total_sent = submitters.count
    @total_opened = submitters.where.not(opened_at: nil).count
    @total_completed = submitters.where.not(completed_at: nil).count
    @total_declined = submitters.where.not(declined_at: nil).count
    @completion_rate = @total_sent.positive? ? (@total_completed.to_f / @total_sent * 100).round(1) : 0
    @avg_time_to_sign = if @total_completed.positive?
                          submitters.where.not(completed_at: nil).average(Arel.sql('EXTRACT(EPOCH FROM completed_at - created_at)'))&.to_f / 3600.0
                        else
                          0
                        end
    @daily_completions = submitters.where.not(completed_at: nil).group(Arel.sql('DATE(completed_at)')).count.sort_by(&:first).last(30)
    @top_templates = current_account.submissions.where(created_at: days..).joins(:template).group('templates.name').count.sort_by do |_, v|
      -v
    end.first(10)
  end

  private

  def authorize_analytics!
    authorize! :read, :analytics
  end
end
