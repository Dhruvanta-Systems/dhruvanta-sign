# frozen_string_literal: true

class ApplicationController < ActionController::Base
  BROWSER_LOCALE_REGEXP = /\A\w{2}(?:-\w{2})?/

  include ActiveStorage::SetCurrent
  include Pagy::Method

  check_authorization unless: :devise_controller?

  around_action :with_locale
  before_action :sign_in_for_demo, if: -> { Docuseal.demo? }
  before_action :maybe_redirect_to_setup, unless: :signed_in?
  before_action :authenticate_user!, unless: :devise_controller?

  before_action :set_csp, if: lambda {
    request.get? && !request.headers['HTTP_X_TURBO_REQUEST_ID'] && !turbo_infinite_scroll?
  }

  helper_method :button_title,
                :current_account,
                :true_ability,
                :form_link_host,
                :svg_icon,
                :current_plan_data,
                :premium_feature?,
                :browser_os,
                :turbo_native_ios?,
                :turbo_native_android?

  impersonates :user, with: ->(uuid) { User.find_by(uuid:) }

  rescue_from Pagy::RangeError do
    redirect_to request.path
  end

  rescue_from RateLimit::LimitApproached do |e|
    Rollbar.error(e) if defined?(Rollbar)

    redirect_back_or_to root_path, alert: 'Too many requests'
  end

  if Rails.env.production? || Rails.env.test?
    rescue_from CanCan::AccessDenied do |e|
      Rollbar.warning(e) if defined?(Rollbar)

      redirect_to root_path, alert: e.message
    end
  end

  def default_url_options
    return {} if Rails.env.test?

    Docuseal.default_url_options
  end

  def impersonate_user(user)
    raise ArgumentError unless user
    raise Pretender::Error unless true_user

    @impersonated_user = user

    request.session[:impersonated_user_id] = user.uuid
  end

  def browser_os
    @browser_os ||= DetectBrowserDevice.os(request.user_agent)
  end

  def pagy_auto(collection, **keyword_args)
    if current_ability.can?(:manage, :countless)
      pagy(:countless, collection, **keyword_args)
    else
      pagy(collection, **keyword_args)
    end
  end

  private

  def turbo_infinite_scroll?
    request.headers['HTTP_X_TURBO_INFINITE_SCROLL'].present?
  end

  def turbo_native_app?
    return @turbo_native_app if defined?(@turbo_native_app)

    @turbo_native_app = request.user_agent.to_s.include?('Hotwire Native')
  end

  def turbo_native_ios?
    return @turbo_native_ios if defined?(@turbo_native_ios)

    @turbo_native_ios = request.user_agent.to_s.include?('Hotwire Native iOS')
  end

  def turbo_native_android?
    return @turbo_native_android if defined?(@turbo_native_android)

    @turbo_native_android = request.user_agent.to_s.include?('Hotwire Native Android')
  end

  def with_locale(&)
    return yield unless current_account

    locale   = params[:lang].presence if Rails.env.development?
    locale ||= current_account.locale

    I18n.with_locale(locale, &)
  end

  def with_browser_locale(&)
    return yield if I18n.locale != :'en-US' && I18n.locale != :en

    locale   = params[:lang].presence
    locale ||= request.env['HTTP_ACCEPT_LANGUAGE'].to_s[BROWSER_LOCALE_REGEXP].to_s

    locale =
      if locale.starts_with?('en-') && locale != 'en-US'
        'en-GB'
      else
        locale.split('-').first.presence || 'en-GB'
      end

    locale = 'en-GB' unless I18n.locale_available?(locale)

    I18n.with_locale(locale, &)
  end

  def sign_in_for_demo
    return if signed_in?

    account = Account.create!(name: "Demo #{SecureRandom.hex(3)}")

    sign_in(account.users.create!(first_name: 'Demo', last_name: 'User',
                                  email: "#{SecureRandom.hex}@docuseal.com", password: SecureRandom.hex))
  end

  def current_account
    current_user&.account
  end

  def true_ability
    @true_ability ||= Ability.new(true_user)
  end

  def maybe_redirect_to_setup
    redirect_to setup_index_path unless User.exists?
  end

  def button_title(title: I18n.t('submit'), disabled_with: I18n.t('submitting'), title_class: '', icon: nil,
                   icon_disabled: nil)
    render_to_string(partial: 'shared/button_title',
                     locals: { title:, disabled_with:, title_class:, icon:, icon_disabled: })
  end

  def svg_icon(icon_name, class: '')
    render_to_string(partial: "icons/#{icon_name}", locals: { class: })
  end

  def form_link_host
    Docuseal.default_url_options[:host]
  end

  def maybe_redirect_com
    return if request.domain != 'docuseal.co'

    redirect_to request.url.gsub('.co/', '.com/'), allow_other_host: true, status: :moved_permanently
  end

  def set_csp
    # Per-request narrowing on top of the baseline policy registered in
    # `config/initializers/content_security_policy.rb`, which is what emits the
    # live header. Keep the directives here aligned with that initializer.
    request.content_security_policy = current_content_security_policy.tap do |policy|
      policy.default_src :self
      policy.script_src  :self, :unsafe_inline
      policy.style_src   :self, :unsafe_inline
      policy.img_src     :self, :data, :blob
      policy.font_src    :self, :data
      policy.manifest_src :self
      policy.media_src   :self
      policy.frame_src   :self
      policy.frame_ancestors :self
      policy.form_action :self
      policy.base_uri    :self
      policy.object_src  :none
      policy.worker_src  :self, :blob
      policy.connect_src :self, 'wss:'
      policy.upgrade_insecure_requests true
      policy.directives.delete('upgrade-insecure-requests') if $disable_upgrade_insecure_requests

      policy.directives['connect-src'] << 'ws:' if Rails.env.development?
    end
  end

  def current_plan_data
    @current_plan_data ||= PremiumBridge.plan_for(current_account&.id)
  end

  def premium_feature?(feature)
    return false unless PremiumBridge.enabled?

    return false unless current_plan_data['status'].to_s == 'active'

    features = current_plan_data['features']
    if features.is_a?(Hash) && (features['features']&.include?('all') || features['features']&.include?(feature.to_s))
      return true
    end
    return true if features.is_a?(Array) && (features.include?('all') || features.include?(feature.to_s))

    false
  end

  def require_premium_feature!(feature)
    return if premium_feature?(feature)

    redirect_to settings_subscriptions_path, alert: "This feature requires a plan upgrade (#{feature})."
  end
end
