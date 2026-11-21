# frozen_string_literal: true

require 'rails_helper'

describe 'Teammate invitations with AUTH_MODE=external', :oidc do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account:) }

  def routable?(verb, path)
    Rails.application.routes.recognize_path(path, method: verb)
    true
  rescue ActionController::RoutingError
    false
  end

  describe 'stock mode' do
    it 'has no invitation routes: users are created by the existing form' do
      expect(routable?(:post, '/account_invitations')).to be(false)
      expect(routable?(:post, '/users')).to be(true)
    end
  end

  context 'with external sign-in' do
    around { |example| with_routes_for(oidc_env('AUTH_MODE' => 'external')) { example.run } }

    it 'draws no password, reset or user-creation route, only invitations' do
      expect(routable?(:post, '/users')).to be(false)
      expect(routable?(:get, '/users/new')).to be(false)
      expect(routable?(:post, '/sign_in')).to be(false)
      expect(routable?(:post, '/password')).to be(false)
      expect(routable?(:get, '/invitation')).to be(false)
      expect(routable?(:post, '/account_invitations')).to be(true)
      expect(Extensions::HostedBoot.local_auth_routes(Rails.application.routes.routes)).to be_empty
    end

    it 'lets an admin invite an email with a role and mails the invitee' do
      sign_in_via_oidc(admin)

      allow(UserMailer).to receive(:account_invitation_email).and_call_original

      expect { post '/account_invitations', params: { account_invitation: { email: 'Mate@Example.test', role: 'viewer' } } }
        .to change(AccountInvitation, :count).by(1)

      invitation = AccountInvitation.last
      expect(invitation).to have_attributes(account_id: account.id, email: 'mate@example.test', role: 'viewer',
                                            invited_by_user_id: admin.id)
      expect(UserMailer).to have_received(:account_invitation_email).with(invitation)
      expect(response).to redirect_to(settings_users_path)
    end

    it 'sends the invitee a mail that tells them to sign in with that address' do
      invitation = AccountInvitation.invite!(account:, email: 'mate@example.test', role: 'viewer')

      mail = UserMailer.account_invitation_email(invitation)

      expect(mail.to).to eq(['mate@example.test'])
      expect(mail.body.encoded).to include('/auth/oidc/start').and include('mate@example.test')
    end

    it 'shows the invite form and the pending list to an admin' do
      AccountInvitation.invite!(account:, email: 'pending@example.test', role: 'editor')
      sign_in_via_oidc(admin)

      get new_account_invitation_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('account_invitation[email]')

      get settings_users_path
      expect(response.body).to include('pending@example.test')
      expect(response.body).not_to include('/users/new')
    end

    it 'refuses people who cannot manage users' do
      sign_in_via_oidc(create(:user, account:, role: 'viewer'))

      expect { post '/account_invitations', params: { account_invitation: { email: 'x@example.test', role: 'admin' } } }
        .not_to change(AccountInvitation, :count)
    end

    it 'does not invite into another account: a removal only touches the own account' do
      other = AccountInvitation.invite!(account: create(:account), email: 'other@example.test', role: 'editor')
      sign_in_via_oidc(admin)

      expect { delete "/account_invitations/#{other.id}" }.to raise_error(ActiveRecord::RecordNotFound)
      expect(AccountInvitation.exists?(other.id)).to be(true)
    end

    it 'lets an admin withdraw an invitation' do
      invitation = AccountInvitation.invite!(account:, email: 'gone@example.test', role: 'editor')
      sign_in_via_oidc(admin)

      expect { delete "/account_invitations/#{invitation.id}" }.to change(AccountInvitation, :count).by(-1)
    end

    it 'refuses a malformed email or role' do
      sign_in_via_oidc(admin)

      expect { post '/account_invitations', params: { account_invitation: { email: 'nope', role: 'admin' } } }
        .not_to change(AccountInvitation, :count)
      expect { post '/account_invitations', params: { account_invitation: { email: 'a@example.test', role: 'root' } } }
        .not_to change(AccountInvitation, :count)
    end

    it 'refuses to invite when the plan has no room for another user' do
      Extensions.register(:plan, Fakes::PlanProvider.new(default: { plan: 'free', status: 'active', features: [],
                                                                    limits: { users: 1 } }))
      sign_in_via_oidc(admin)

      expect { post '/account_invitations', params: { account_invitation: { email: 'a@example.test', role: 'admin' } } }
        .not_to change(AccountInvitation, :count)
      expect(flash[:alert]).to match(/plan limit/i)
    end

    context 'when the invited person signs in', :oidc do
      it 'joins the inviting account with the invited role (verified email)' do
        AccountInvitation.invite!(account:, email: 'ada@example.com', role: 'viewer')

        oidc_sign_in

        user = User.find_by!(email: 'ada@example.com')
        expect(user).to have_attributes(account_id: account.id, role: 'viewer', sso_subject: fake_provider.subject)
        expect(Account.count).to eq(1)

        get '/'
        expect(response.body).to include('Sign out')
      end

      it 'does not join when the provider does not assert a verified email' do
        AccountInvitation.invite!(account:, email: 'ada@example.com', role: 'viewer')
        fake_provider.claims = { email_verified: false }

        oidc_sign_in

        expect(response).to have_http_status(:forbidden)
        expect(AccountInvitation.pending.count).to eq(1)
        expect(User.where(email: 'ada@example.com')).to be_empty
      end
    end
  end
end
