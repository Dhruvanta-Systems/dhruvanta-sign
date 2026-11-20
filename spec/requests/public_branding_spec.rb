# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Public branding' do
  let(:account) { create(:account) }
  let!(:user) { create(:user, account:) }

  it 'makes Dhruvanta Sign primary in public landing metadata and keeps DocuSeal attribution secondary' do
    get '/'

    expect(response).to have_http_status(:ok)

    page = Nokogiri::HTML(response.body)

    expect(page.at_css('title').text.squish).to eq('Dhruvanta Sign | Secure Document Signing')
    expect(page.at_css('meta[property="og:site_name"]')['content']).to eq('Dhruvanta Sign')
    expect(page.at_css('h1').text.squish).to eq('Dhruvanta Sign')
    expect(response.body).to include('Powered by')
    expect(response.body).to include('DocuSeal')
    expect(Docuseal.product_name).to eq('DocuSeal')
  end

  it 'uses the display branding in the dynamic PWA manifest' do
    get '/manifest.json'

    expect(response).to have_http_status(:ok)

    manifest = JSON.parse(response.body)

    expect(manifest['name']).to eq('Dhruvanta Sign')
    expect(manifest['short_name']).to eq('Dhruvanta Sign')
    expect(manifest['description']).to include('Dhruvanta Sign')
    expect(manifest['description']).to include('powered by DocuSeal')
    expect(Docuseal.product_name).to eq('DocuSeal')
  end
end
