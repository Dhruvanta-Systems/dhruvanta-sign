# frozen_string_literal: true

# Loads operator adapters and applies the hosted-mode profile (see Extensions and
# Extensions::HostedBoot).

# Optional in-process adapters: every config/extensions.d/*.rb file is loaded
# here and is expected to call Extensions.register. Generic adapters only; anything
# specific to one operator belongs behind HTTP (see Extensions::Http).
Rails.root.glob('config/extensions.d/*.rb').sort.each { |file| require file }

Rails.application.config.to_prepare do
  ActionMailer::Base.add_delivery_method(:extension_notifier, Extensions::NotifierDeliveryMethod)
end

if Extensions.hosted?
  # Every mail goes to the notifier, and a failed delivery must be loud.
  Rails.application.config.action_mailer.delivery_method = :extension_notifier
  Rails.application.config.action_mailer.raise_delivery_errors = true

  Rails.application.config.after_initialize { Extensions::HostedBoot.verify! }
end
