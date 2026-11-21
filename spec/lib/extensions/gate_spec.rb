# frozen_string_literal: true

require 'rails_helper'

describe Extensions::Gate do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:template) { create(:template, account:, author: user) }
  let(:provider) { Fakes::PlanProvider.new }

  def plan(limits: {}, **overrides)
    { plan: 'free', status: 'active', features: [], limits:, suspended: false }.merge(overrides)
  end

  def create_submission
    create(:submission, template:, created_by_user: user)
  end

  context 'with no plan provider' do
    it 'limits nothing and suspends nobody' do
      expect { 3.times { create_submission } }.not_to raise_error
      expect(Extensions.within_limit?(account, :docs)).to be(true)
      expect(Extensions.suspended?(account)).to be(false)
    end
  end

  context 'with a plan provider' do
    before { Extensions.register(:plan, provider) }

    describe 'the submission quota' do
      it 'allows submissions up to the limit and refuses the next one BEFORE it exists' do
        provider.set(account.id, plan(limits: { docs: 2 }))

        2.times { create_submission }

        expect { create_submission }.to raise_error(Extensions::LimitExceeded, /docs/)
        expect(Submission.where(account_id: account.id).count).to eq(2)
      end

      it 'counts only the current month' do
        provider.set(account.id, plan(limits: { docs: 1 }))
        old = create_submission
        old.update_columns(created_at: 2.months.ago)

        expect { create_submission }.not_to raise_error
        expect { create_submission }.to raise_error(Extensions::LimitExceeded)
      end

      it 'treats a limit the plan does not name as unlimited' do
        provider.set(account.id, plan(limits: { sends: 1 }))

        expect { 3.times { create_submission } }.not_to raise_error
      end

      it 'counts a whole batch against the limit with within_limit?' do
        provider.set(account.id, plan(limits: { docs: 5 }))

        expect(Extensions.within_limit?(account, :docs, add: 5)).to be(true)
        expect(Extensions.within_limit?(account, :docs, add: 6)).to be(false)
      end
    end

    describe 'the send quota' do
      before { provider.set(account.id, plan(limits: { sends: 2 })) }

      def record_sends(count)
        submission = create_submission
        submitter = create(:submitter, submission:, uuid: SecureRandom.uuid)
        count.times { SubmissionEvent.create!(submitter:, event_type: 'send_email') }
      end

      it 'refuses a send once the monthly quota is used' do
        record_sends(2)

        expect { described_class.check_send!(account) }.to raise_error(Extensions::LimitExceeded, /sends/)
        expect(described_class.send_allowed?(account)).to be(false)
      end

      it 'allows a send inside the quota' do
        record_sends(1)

        expect(described_class.send_allowed?(account)).to be(true)
      end

      it 'stops the invitation job before the mail is built' do
        record_sends(2)
        submitter = create(:submitter, submission: create_submission, uuid: SecureRandom.uuid, email: 'a@example.test')
        allow(SubmitterMailer).to receive(:invitation_email)

        SendSubmitterInvitationEmailJob.new.perform('submitter_id' => submitter.id)

        expect(SubmitterMailer).not_to have_received(:invitation_email)
      end
    end

    describe 'the suspend switch' do
      before { provider.set(account.id, plan(limits: { docs: 100, sends: 100 }, suspended: true)) }

      it 'stops a suspended account from creating submissions' do
        expect { create_submission }.to raise_error(Extensions::AccountSuspended)
      end

      it 'stops a suspended account from sending, even with quota left' do
        expect { described_class.check_send!(account) }.to raise_error(Extensions::AccountSuspended)
      end

      it 'also reads a suspended status' do
        provider.set(account.id, plan(status: 'suspended'))

        expect(Extensions.suspended?(account)).to be(true)
      end

      it 'never lets a suspended account use a feature' do
        provider.set(account.id, plan(features: %w[all], suspended: true))

        expect(Extensions.feature?(account, 'analytics')).to be(false)
      end

      it 'does not touch other accounts' do
        other = create(:account)

        expect { described_class.check_send!(other) }.not_to raise_error
      end
    end

    describe 'when the plan service is unavailable for too long' do
      it 'refuses to create or send (fail closed)' do
        provider.fail_with = StandardError.new('down')

        expect { create_submission }.to raise_error(Extensions::PlanUnavailable)
        expect { described_class.check_send!(account) }.to raise_error(Extensions::PlanUnavailable)
      end
    end

    describe 'feature gates' do
      it 'allows a feature the plan lists, and everything for "all"' do
        provider.set(account.id, plan(features: %w[analytics]))

        expect(Extensions.feature?(account, 'analytics')).to be(true)
        expect(Extensions.feature?(account, 'bulk_send')).to be(false)

        provider.set(account.id, plan(features: %w[all]))
        Extensions::PlanCache.clear!

        expect(Extensions.feature?(account, 'bulk_send')).to be(true)
      end

      it 'needs an active plan' do
        provider.set(account.id, plan(features: %w[all], status: 'past_due'))

        expect(Extensions.feature?(account, 'analytics')).to be(false)
      end

      it 'reads the older features-in-a-hash answer' do
        provider.set(account.id, plan(features: { 'features' => %w[approvals] }))

        expect(Extensions.feature?(account, 'approvals')).to be(true)
      end
    end
  end

  describe '.rate_limit!' do
    around do |example|
      with_env('ABUSE_CONTROLS' => 'true', 'RATE_LIMIT_ACCOUNT' => '3', 'RATE_LIMIT_IP' => '5') { example.run }
    end

    it 'refuses an account that goes over its limit, whatever the address' do
      3.times { |i| described_class.rate_limit!(account:, ip: "10.0.0.#{i}") }

      expect { described_class.rate_limit!(account:, ip: '10.0.1.1') }.to raise_error(RateLimit::LimitApproached)
    end

    it 'refuses an address that goes over its limit, whatever the account' do
      5.times { described_class.rate_limit!(account: create(:account), ip: '10.9.9.9') }

      expect { described_class.rate_limit!(account: create(:account), ip: '10.9.9.9') }
        .to raise_error(RateLimit::LimitApproached)
    end

    it 'does not limit other accounts or addresses' do
      3.times { described_class.rate_limit!(account:, ip: '10.0.0.1') }

      expect(described_class.rate_limit!(account: create(:account), ip: '10.0.0.2')).to be_truthy
    end

    it 'is off outside hosted mode unless ABUSE_CONTROLS is set' do
      with_env('ABUSE_CONTROLS' => nil, 'HOSTED_MODE' => nil) do
        expect { 10.times { described_class.rate_limit!(account:, ip: '10.0.0.1') } }.not_to raise_error
      end
    end

    it 'is on in hosted mode' do
      with_env('ABUSE_CONTROLS' => nil, 'HOSTED_MODE' => 'true') do
        3.times { described_class.rate_limit!(account:, ip: '10.0.0.1') }

        expect { described_class.rate_limit!(account:, ip: '10.0.0.1') }.to raise_error(RateLimit::LimitApproached)
      end
    end
  end
end
