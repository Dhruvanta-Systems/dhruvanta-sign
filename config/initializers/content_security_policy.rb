# frozen_string_literal: true

# Default Content-Security-Policy for the DocuSeal Rails app.
#
# Baseline Content-Security-Policy. `ApplicationController#set_csp` narrows it
# per request, but without a default policy registered here
# `current_content_security_policy` is nil at request time and live responses
# carry no `Content-Security-Policy` header at all.
#
# This initializer registers the baseline through Rails' built-in
# `content_security_policy` DSL so the middleware emits the header on every
# response.
#
# Directive choices are tuned for the signer surface:
# - `frame-ancestors 'self'` (NOT `'none'`): the embed surface
#   (`/d/<token>/embed`) needs to render inside same-origin parent
#   frames. Cross-origin framing is still blocked.
# - `script-src 'self' 'unsafe-inline'`: Rails ships some inline scripts
#   via Importmap and Stimulus controllers. The nonce strategy in
#   `config/application.rb` covers `script-src` for views that opt in.
# - `style-src 'self' 'unsafe-inline'`: Rails inline `style="..."` in
#   ERB views and dynamic Vue component styles.
# - `img-src 'self' data: blob:`: signature canvas exports (`data:`,
#   `blob:`) and inline brand imagery only. No remote image origins.
# - `connect-src 'self' wss:`: Action Cable WebSocket plus same-origin
#   XHR/fetch.
# - `upgrade-insecure-requests`: backstop in case any legacy `http://`
#   asset reference slips through.

Rails.application.config.content_security_policy do |policy|
  policy.default_src :self
  policy.script_src  :self, :unsafe_inline
  policy.style_src   :self, :unsafe_inline
  policy.img_src     :self, :data, :blob
  policy.font_src    :self, :data
  policy.connect_src :self, 'wss:'
  policy.frame_ancestors :self
  policy.form_action :self
  policy.base_uri    :self
  policy.object_src  :none
  policy.upgrade_insecure_requests true
end
