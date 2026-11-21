# frozen_string_literal: true

require 'rails_helper'

# Sign-in identifies a person by the provider's stable (issuer, subject). An email
# address is only used to link a user that has no identity yet and to bind an
# invitation, and only when the provider asserts it is verified.
describe JwtSso::HandoffService do
  let(:issuer) { 'https://idp.example.test' }

  around { |example| with_env('JWT_SSO_ISSUER' => issuer) { example.run } }

  def handoff(subject:, email: nil, verified: true)
    described_class::VerifiedHandoff.new(jti: SecureRandom.uuid, subject:, email:, email_verified: verified,
                                         display_name: 'Ada Lovelace')
  end

  def sign_in(**)
    described_class.new.lookup_or_provision_user(handoff(**))
  end

  it 'creates a user bound to the issuer and the subject on first sign-in' do
    user = sign_in(subject: 'sub-a', email: 'ada@example.test')

    expect(user).to have_attributes(sso_issuer: issuer, sso_subject: 'sub-a', email: 'ada@example.test')
    expect(user.account).to be_present
  end

  it 'finds the same user by subject on every later sign-in' do
    first = sign_in(subject: 'sub-a', email: 'ada@example.test')

    expect(sign_in(subject: 'sub-a', email: 'ada@example.test')).to eq(first)
    expect(User.count).to eq(1)
  end

  it 'finds the user by subject even when the provider no longer sends a verified email' do
    first = sign_in(subject: 'sub-a', email: 'ada@example.test')

    expect(sign_in(subject: 'sub-a', email: 'ada@example.test', verified: false)).to eq(first)
    expect(sign_in(subject: 'sub-a')).to eq(first)
    expect(first.reload.email).to eq('ada@example.test')
  end

  it 'keeps the person in the same account when their verified email changes, and follows the new address' do
    first = sign_in(subject: 'sub-a', email: 'ada@example.test')

    again = sign_in(subject: 'sub-a', email: 'ada.new@example.test')

    expect(again).to eq(first)
    expect(again.reload.email).to eq('ada.new@example.test')
    expect(User.count).to eq(1)
  end

  it 'does not take an address another user holds when following an email change' do
    first = sign_in(subject: 'sub-a', email: 'ada@example.test')
    create(:user, email: 'taken@example.test')

    expect(sign_in(subject: 'sub-a', email: 'taken@example.test')).to eq(first)
    expect(first.reload.email).to eq('ada@example.test')
  end

  describe 'a recycled email address' do
    it 'does not land the new owner in the old account once the old person has moved on' do
      old_user = sign_in(subject: 'sub-old', email: 'shared@example.test')
      sign_in(subject: 'sub-old', email: 'moved@example.test') # the address is freed

      new_user = sign_in(subject: 'sub-new', email: 'shared@example.test')

      expect(new_user).not_to eq(old_user)
      expect(new_user.account_id).not_to eq(old_user.account_id)
      expect(new_user.email).to eq('shared@example.test')
      expect(old_user.reload.email).to eq('moved@example.test')
    end

    it 'is refused, not handed the old account, while the old user still holds the address' do
      old_user = sign_in(subject: 'sub-old', email: 'shared@example.test')

      expect { sign_in(subject: 'sub-new', email: 'shared@example.test') }
        .to raise_error(described_class::HandoffError) { |error|
          expect(error.code).to eq('sso-handoff-email-bound')
          expect(error.http_status).to eq(:conflict)
        }
      expect(User.count).to eq(1)
      expect(old_user.reload.sso_subject).to eq('sub-old')
    end

    it 'does not move an invitation for the old address into the new owner when the old user holds it' do
      inviter = create(:user)
      old_user = sign_in(subject: 'sub-old', email: 'shared@example.test')
      AccountInvitation.invite!(account: inviter.account, email: 'other@example.test', role: 'viewer')

      expect { sign_in(subject: 'sub-new', email: 'shared@example.test') }.to raise_error(described_class::HandoffError)
      expect(old_user.reload.account_id).not_to eq(inviter.account_id)
    end
  end

  describe 'linking by email' do
    it 'binds a user that has no identity yet when the provider asserts the address is verified' do
      legacy = create(:user, email: 'legacy@example.test')

      user = sign_in(subject: 'sub-l', email: 'legacy@example.test')

      expect(user).to eq(legacy)
      expect(legacy.reload).to have_attributes(sso_issuer: issuer, sso_subject: 'sub-l')
    end

    it 'then refuses a second subject for the same address' do
      create(:user, email: 'legacy@example.test')
      sign_in(subject: 'sub-l', email: 'legacy@example.test')

      expect { sign_in(subject: 'sub-other', email: 'legacy@example.test') }
        .to raise_error(described_class::HandoffError, 'sso-handoff-email-bound')
    end

    it 'never links by an address the provider does not assert is verified' do
      legacy = create(:user, email: 'legacy@example.test')

      user = sign_in(subject: 'sub-x', email: 'legacy@example.test', verified: false)

      expect(user).not_to eq(legacy)
      expect(legacy.reload.sso_subject).to be_nil
      expect(user.email).to eq('sso-sub-x@sso-handoff.invalid')
    end

    it 'binds an invitation by verified address and records the identity on the new user' do
      inviter = create(:user)
      AccountInvitation.invite!(account: inviter.account, email: 'mate@example.test', role: 'viewer')

      user = sign_in(subject: 'sub-m', email: 'mate@example.test')

      expect(user).to have_attributes(account_id: inviter.account_id, role: 'viewer', sso_subject: 'sub-m',
                                      sso_issuer: issuer)
      expect(sign_in(subject: 'sub-m', email: 'mate@example.test')).to eq(user)
    end
  end

  it 'keeps the same subject at another issuer a different person' do
    first = sign_in(subject: 'sub-a', email: 'ada@example.test')

    other = with_env('JWT_SSO_ISSUER' => 'https://other-idp.example.test') do
      sign_in(subject: 'sub-a', email: 'ada2@example.test')
    end

    expect(other).not_to eq(first)
  end

  it 'refuses a handoff with no subject' do
    expect { sign_in(subject: '', email: 'ada@example.test') }
      .to raise_error(described_class::HandoffError, 'sso-handoff-missing-sub')
  end

  it 'cannot store two users for one identity' do
    sign_in(subject: 'sub-a', email: 'ada@example.test')

    expect { create(:user, sso_issuer: issuer, sso_subject: 'sub-a') }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end
