# frozen_string_literal: true

require 'rails_helper'

# Hosted mode: every /file, /blobs_proxy and /disk URL path is plain ASCII (a gateway
# can refuse any percent-escape), and the download still carries the real name in
# Content-Disposition (RFC 6266 filename*).
describe 'Download URLs' do
  let(:user) { create(:user) }
  let(:template) { create(:template, account: user.account, author: user, attachment_count: 0) }
  let(:names) { ['My Contract.pdf', 'ఒప్పందం పత్రం.pdf', 'अनुबंध दस्तावेज़.pdf', '📄 Plan 🚀.pdf', '★★★ !!!.pdf'] }

  def attach(filename)
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new('%PDF-1.4 fake'), filename:,
                                                  content_type: 'application/pdf')
    template.documents.attach(blob)
    blob
  end

  def path_part(url)
    URI.parse(url).path
  end

  def content_disposition
    response.headers['Content-Disposition']
  end

  describe 'proxy URLs (/file and /blobs_proxy)' do
    it 'keep the real name in the path outside hosted mode (stock is unchanged)' do
      blob = attach('My Contract.pdf')

      expect(ActiveStorage::Blob.proxy_path(blob, expires_at: 1.hour.from_now)).to end_with('/My%20Contract.pdf')
      expect(path_part(ActiveStorage::Blob.proxy_url(blob))).to end_with('/My%20Contract.pdf')
    end

    context 'when hosted' do
      around { |example| with_env('HOSTED_MODE' => 'true') { example.run } }

      it 'puts an ASCII slug and no % in every proxy path and url' do
        names.each do |name|
          blob = attach(name)

          [ActiveStorage::Blob.proxy_path(blob, expires_at: 1.hour.from_now),
           path_part(ActiveStorage::Blob.proxy_url(blob, expires_at: 1.hour.from_now))].each do |path|
            expect(path).not_to include('%')
            expect(path).to match(%r{\A/file/[^/]+/[a-z0-9._-]+\z})
          end
        end
      end

      it 'slugs a name that was passed in explicitly (the account filename format)' do
        blob = attach('x.pdf')

        path = ActiveStorage::Blob.proxy_path(blob, expires_at: 1.hour.from_now, filename: 'Contract – Ada L. (signed).pdf')

        expect(path).to end_with('/contract-ada-l.-signed.pdf')
      end

      it 'uses a fallback name when nothing is left, and keeps the extension' do
        expect(ActiveStorage::Blob.proxy_path(attach('ఒప్పందం.pdf'), expires_at: 1.hour.from_now)).to end_with('/file.pdf')
        expect(ActiveStorage::Blob.proxy_path(attach('★★★.pdf'), expires_at: 1.hour.from_now)).to end_with('/file.pdf')
      end

      it 'still serves the file, with the real name in Content-Disposition' do
        blob = attach('My Contract.pdf')

        get ActiveStorage::Blob.proxy_path(blob, expires_at: 1.hour.from_now)

        expect(response).to have_http_status(:ok)
        expect(content_disposition).to include('filename="My Contract.pdf"')
        expect(content_disposition).to include("filename*=UTF-8''My%20Contract.pdf")
      end

      it 'keeps Telugu, Hindi and emoji names in Content-Disposition while the URL stays ASCII' do
        {
          'ఒప్పందం పత్రం.pdf' => 'UTF-8\'\'%E0%B0%92%E0%B0%AA%E0%B1%8D%E0%B0%AA%E0%B0%82%E0%B0%A6%E0%B0%82%20',
          'अनुबंध दस्तावेज़.pdf' => "UTF-8''%E0%A4%85%E0%A4%A8%E0%A5%81",
          '📄 Plan 🚀.pdf' => "UTF-8''%F0%9F%93%84%20Plan%20%F0%9F%9A%80.pdf"
        }.each do |name, encoded_start|
          path = ActiveStorage::Blob.proxy_path(attach(name), expires_at: 1.hour.from_now)
          expect(path).not_to include('%')

          get path

          expect(response).to have_http_status(:ok)
          expect(content_disposition).to include("filename*=#{encoded_start}")
        end
      end

      it 'keeps the real name for a ranged download too' do
        blob = attach('My Contract.pdf')

        get ActiveStorage::Blob.proxy_path(blob, expires_at: 1.hour.from_now), headers: { 'Range' => 'bytes=0-3' }

        expect(response).to have_http_status(:partial_content)
        expect(content_disposition).to include("filename*=UTF-8''My%20Contract.pdf")
      end
    end
  end

  describe 'disk service URLs (/disk)' do
    before { ActiveStorage::Current.url_options = { host: 'www.example.com', protocol: 'http' } }

    after { ActiveStorage::Current.reset }

    it 'keep the real name in the path outside hosted mode' do
      blob = attach('My Contract.pdf')

      expect(path_part(blob.url)).to end_with('/My%20Contract.pdf')
    end

    context 'when hosted' do
      around { |example| with_env('HOSTED_MODE' => 'true') { example.run } }

      it 'put an ASCII slug and no % in the path' do
        names.each do |name|
          path = path_part(attach(name).url)

          expect(path).not_to include('%')
          expect(path).to match(%r{\A/disk/[^/]+/[a-z0-9._-]+\z})
        end
      end

      it 'still serve the file with the real name in Content-Disposition' do
        url = attach('My Contract.pdf').url

        get path_part(url)

        expect(response).to have_http_status(:ok)
        expect(content_disposition).to include("filename*=UTF-8''My%20Contract.pdf")
      end

      it 'keep a non-ASCII name in Content-Disposition while the path is ASCII' do
        url = attach('ఒప్పందం పత్రం.pdf').url

        expect(path_part(url)).to end_with('/file.pdf')

        get path_part(url)

        expect(response).to have_http_status(:ok)
        expect(content_disposition).to include("filename*=UTF-8''%E0%B0%92")
      end
    end
  end
end
