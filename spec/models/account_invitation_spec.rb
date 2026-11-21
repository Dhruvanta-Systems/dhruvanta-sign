# frozen_string_literal: true

require 'rails_helper'

describe AccountInvitation do
  include ActiveSupport::Testing::TimeHelpers

  let(:account) { create(:account) }
  let(:admin) { create(:user, account:) }

  def invite(email = 'New.Person@Example.test', role: 'editor')
    described_class.invite!(account:, invited_by: admin, email:, role:)
  end

  around { |example| with_env('OIDC_ISSUER' => 'https://op.example.com') { example.run } }

  # A sign-in as the OpenID Connect client does it, after the id_token is verified.
  def provision(email:)
    Oidc::Linker.call({ 'sub' => SecureRandom.uuid, 'email' => email, 'email_verified' => true, 'name' => 'New Person' })
  end

  it 'stores the email in lower case with a role and an expiry' do
    invitation = invite

    expect(invitation).to have_attributes(email: 'new.person@example.test', role: 'editor', accepted_at: nil)
    expect(invitation.expires_at).to be_within(1.minute).of(7.days.from_now)
  end

  it 'only accepts the account roles' do
    expect(described_class.new(account:, email: 'a@example.test', role: 'integration')).not_to be_valid
    expect(described_class.new(account:, email: 'a@example.test', role: 'owner')).not_to be_valid
  end

  it 'refuses an email that already has a user' do
    create(:user, email: 'taken@example.test')

    expect { invite('taken@example.test') }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it 'replaces an earlier unused invitation for the same email' do
    first = invite
    second = invite('new.person@example.test', role: 'viewer')

    expect(described_class.where(email: 'new.person@example.test').pluck(:id, :role)).to eq([[second.id, 'viewer']])
    expect(described_class.exists?(first.id)).to be(false)
  end

  describe 'joining by signing in through the external provider' do
    it 'puts a person with a VERIFIED invited email into the inviting account with the invited role' do
      invite(role: 'viewer')

      user = provision(email: 'new.person@example.test')

      expect(user.account_id).to eq(account.id)
      expect(user.role).to eq('viewer')
      expect(user.email).to eq('new.person@example.test')
      expect(Account.count).to eq(1)
      expect(described_class.sole).to have_attributes(accepted_user_id: user.id).and(satisfy { |i| i.accepted_at.present? })
    end

    it 'is single use' do
      invite

      first = described_class.accept!(email: 'new.person@example.test', first_name: 'A', last_name: 'B')
      second = described_class.accept!(email: 'new.person@example.test', first_name: 'A', last_name: 'B')

      expect(first).to be_a(User)
      expect(second).to be_nil
      expect(User.where(email: 'new.person@example.test').count).to eq(1)
    end

    it 'does not let two sign-ins both use it' do
      invite
      accepted = Array.new(2) do
        described_class.accept!(email: 'new.person@example.test', first_name: 'A', last_name: 'B')
      rescue ActiveRecord::RecordInvalid
        nil
      end

      expect(accepted.compact.size).to eq(1)
    end

    it 'expires' do
      invite

      travel_to(8.days.from_now) do
        user = provision(email: 'new.person@example.test')

        expect(user.account_id).not_to eq(account.id)
      end
    end

    it 'honours INVITATION_TTL_DAYS' do
      with_env('INVITATION_TTL_DAYS' => '1') do
        invite

        travel_to(2.days.from_now) { expect(described_class.pending).to be_empty }
      end
    end

    it 'does not join someone else with a different email' do
      invite

      user = provision(email: 'someone.else@example.test')

      expect(user.account_id).not_to eq(account.id)
    end

    it 'does not move an existing user into the inviting account' do
      existing = create(:user, email: 'new.person@example.test')

      expect { provision(email: 'new.person@example.test') }.to raise_error(Oidc::Error)

      expect(existing.reload.account_id).not_to eq(account.id)
    end

    it 'is refused by the users limit and stays usable' do
      admin
      invite
      provider = Fakes::PlanProvider.new(default: { plan: 'free', status: 'active', features: [], limits: { users: 1 } })
      Extensions.register(:plan, provider)

      expect { provision(email: 'new.person@example.test') }.to raise_error(Extensions::LimitExceeded)
      expect(described_class.pending.count).to eq(1)
    end
  end
end
