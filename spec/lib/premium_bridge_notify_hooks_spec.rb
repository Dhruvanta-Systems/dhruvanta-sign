# frozen_string_literal: true

require 'rails_helper'

# The companion no longer accepts the submitter.created hook, so the app must not send it.
describe PremiumBridge, '.notify hooks' do
  it 'does not emit submitter.created when a submitter is created' do
    allow(described_class).to receive(:enabled?).and_return(true)
    allow(described_class).to receive(:notify)
    load Rails.root.join('config/initializers/premium_hooks.rb')
    submitter = instance_double(Submitter, phone: '+15550100', email: 'a@example.com', slug: 'abc',
                                           account_id: 1, id: 1)

    ActiveSupport.run_load_hooks(:after_submitter_created, submitter)

    expect(described_class).not_to have_received(:notify).with('submitter.created', anything)
  end
end
