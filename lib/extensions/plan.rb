# frozen_string_literal: true

module Extensions
  # What a plan provider said about one account, normalized.
  #
  #   plan       name of the plan ("free", "pro", ...)
  #   status     "active" for a plan in good standing; features need this
  #   features   Array of feature keys, or ["all"]
  #   limits     { docs:, users:, templates:, sends: }; a missing or nil key is unlimited
  #   suspended  true when the account may not send or create anything
  #
  # `Plan.closed` is what the gate uses when the provider is down for longer than
  # the allowed stale age: nothing is allowed.
  class Plan
    SUSPENDED_STATUSES = %w[suspended blocked].freeze

    attr_reader :name, :status, :features, :limits, :title

    def self.from(raw)
      return closed unless raw.respond_to?(:to_h)

      data = raw.to_h.with_indifferent_access

      new(name: data[:plan].presence || 'free',
          status: data[:status].to_s,
          features: normalize_features(data[:features]),
          limits: normalize_limits(data[:limits]),
          suspended: data[:suspended] == true || SUSPENDED_STATUSES.include?(data[:status].to_s),
          title: data[:title])
    end

    def self.closed
      new(name: 'unavailable', status: 'unavailable', features: [], limits: {}, suspended: false, unavailable: true)
    end

    def self.normalize_features(value)
      list = value.is_a?(Hash) ? value['features'] || value[:features] : value

      Array(list).map(&:to_s)
    end

    def self.normalize_limits(value)
      return {} unless value.respond_to?(:to_h)

      value.to_h.each_with_object({}) do |(key, item), acc|
        acc[key.to_sym] = item.nil? || item.to_s == 'unlimited' ? nil : item.to_i
      end
    end

    def initialize(name:, status:, features:, limits:, suspended:, title: nil, unavailable: false)
      @name = name
      @status = status
      @features = features
      @limits = limits
      @suspended = suspended
      @title = title
      @unavailable = unavailable
    end

    def suspended? = @suspended

    def unavailable? = @unavailable

    # May the account do anything that costs us something?
    def usable? = !unavailable? && !suspended?

    def active? = status == 'active'

    def feature?(key)
      active? && usable? && (features.include?('all') || features.include?(key.to_s))
    end

    # nil means unlimited.
    def limit(key) = limits[key.to_sym]
  end
end
