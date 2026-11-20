# frozen_string_literal: true

require 'rails_helper'

# LICENSE_ADDITIONAL_TERMS (AGPL section 7(b)) requires the original DocuSeal
# attribution to stay visible in interactive user interfaces. This asserts it is
# rendered on the admin pages (layouts/application, partial shared/_powered_by)
# and on the signer pages (submit_form/show, partial shared/_attribution).
RSpec.describe 'DocuSeal attribution' do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }

  def attribution_link(html)
    Nokogiri::HTML(html).css('a[href^="https://www.docuseal.com"]').find { |a| a.text.strip == 'DocuSeal' }
  end

  def source_code_link(html)
    Nokogiri::HTML(html).at_css('a[data-source-code-link]')
  end

  it 'links to the source code on the admin footer, next to the attribution' do
    sign_in user

    get '/settings/profile'

    footer = Nokogiri::HTML(response.body).at_css('#docuseal_attribution')
    link = source_code_link(footer.to_html)
    expect(link).to be_present
    expect(link['href']).to eq('https://github.com/Dhruvanta-Systems/dhruvanta-sign')
    expect(link.text.strip).to eq('Source code')
  end

  it 'links to the source code on a signer page, next to the attribution' do
    template = create(:template, account:, author: user)
    submission = create(:submission, :with_submitters, template:, created_by_user: user)

    get "/s/#{submission.submitters.first.slug}"

    expect(source_code_link(response.body)).to be_present
    expect(source_code_link(response.body)['href']).to eq('https://github.com/Dhruvanta-Systems/dhruvanta-sign')
    expect(response.body).to include('data-source-code-url="https://github.com/Dhruvanta-Systems/dhruvanta-sign"')
  end

  it 'honours SOURCE_CODE_URL', :aggregate_failures do
    stub_const('Docuseal::SOURCE_CODE_URL', 'https://example.test/src')
    sign_in user

    get '/settings/profile'

    expect(source_code_link(response.body)['href']).to eq('https://example.test/src')
  end

  it 'is shown on the admin pages' do
    sign_in user

    get '/settings/profile'

    expect(response).to have_http_status(:ok)
    footer = Nokogiri::HTML(response.body).at_css('#docuseal_attribution')
    expect(footer).to be_present
    expect(footer.text).to include('Powered by')
    expect(attribution_link(footer.to_html)).to be_present
  end

  it 'is shown on the sign-in page' do
    user

    get '/sign_in'

    expect(response).to have_http_status(:ok)
    expect(attribution_link(response.body)).to be_present
  end

  it 'is shown on the signer page' do
    template = create(:template, account:, author: user)
    submission = create(:submission, :with_submitters, template:, created_by_user: user)
    submitter = submission.submitters.first

    get "/s/#{submitter.slug}"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Powered by')
    expect(attribution_link(response.body)).to be_present
  end
end
