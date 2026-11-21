# frozen_string_literal: true

require 'rails_helper'

describe 'Signer code form in hosted mode' do
  let(:otp) { Fakes::OtpProvider.new }

  around { |example| with_env('HOSTED_MODE' => 'true') { example.run } }

  before { Extensions.register(:otp, otp) }

  it 'has the signer code form check the code with the provider' do
    user = create(:user)
    template = create(:template, account: user.account, author: user)
    submission = create(:submission, template:, created_by_user: user)
    submitter = create(:submitter, submission:, uuid: SecureRandom.uuid, email: 'signer@example.test')

    post '/submit_form_email_2fa', params: { submitter_slug: submitter.slug, one_time_code: '000000' }
    expect(response.location).to include('status=error')

    post '/submit_form_email_2fa', params: { submitter_slug: submitter.slug, one_time_code: '123456' }
    expect(response.location).not_to include('status=error')
    expect(otp.verified.size).to eq(2)
  end
end
