# frozen_string_literal: true

require 'rails_helper'

# Every signer-facing entry point that is keyed by a submitter slug must refuse a
# link that is completed, declined, expired or archived, the same way the main
# signer page does. The table at the bottom of this file lists each entry point
# and where its own check lives; this spec exercises the ones that were missing
# the check.
RSpec.describe 'Signer entry points and submission state' do
  let(:account) { create(:account) }
  let(:author) { create(:user, account:) }
  let(:template) { create(:template, account:, author:, submitter_count: 1, only_field_types: %w[text signature]) }
  let(:submission) { create(:submission, :with_submitters, template:) }
  let(:submitter) { submission.submitters.first }

  close_states = {
    'completed' => ->(ctx) { ctx.submitter.update!(completed_at: Time.current) },
    'declined' => ->(ctx) { ctx.submitter.update!(declined_at: Time.current) },
    'expired' => ->(ctx) { ctx.submission.update!(expire_at: 1.hour.ago) },
    'archived submission' => ->(ctx) { ctx.submission.update!(archived_at: Time.current) },
    'archived template' => ->(ctx) { ctx.template.update!(archived_at: Time.current) },
    'archived account' => ->(ctx) { ctx.account.update!(archived_at: Time.current) }
  }.freeze

  def audio_upload
    Rack::Test::UploadedFile.new(StringIO.new('webm-bytes'), 'audio/webm', original_filename: 'v.webm')
  end

  describe 'GET /embed/form/:slug' do
    it 'renders the form while the link is open' do
      get "/embed/form/#{submitter.slug}"

      expect(response).to have_http_status(:ok)
    end

    close_states.each do |name, close|
      it "answers 410 when the link is #{name}" do
        close.call(self)

        get "/embed/form/#{submitter.slug}"

        expect(response).to have_http_status(:gone)
      end
    end

    it 'answers 403 when email 2FA has not been passed' do
      submitter.update!(preferences: submitter.preferences.merge('require_email_2fa' => true))

      get "/embed/form/#{submitter.slug}"

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'POST /s/:slug/voice_signature' do
    it 'stores the recording while the link is open' do
      expect { post "/s/#{submitter.slug}/voice_signature", params: { audio: audio_upload } }
        .to change { submitter.attachments.count }.by(1)

      expect(response).to have_http_status(:ok)
    end

    close_states.each do |name, close|
      it "refuses and stores nothing when the link is #{name}" do
        close.call(self)

        expect { post "/s/#{submitter.slug}/voice_signature", params: { audio: audio_upload } }
          .not_to(change(ActiveStorage::Attachment, :count))

        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end

  describe 'video verification' do
    it 'answers while the link is open' do
      get "/s/#{submitter.slug}/video_kyc"

      expect(response).to have_http_status(:ok)
    end

    close_states.each do |name, close|
      it "refuses show and create when the link is #{name}" do
        close.call(self)

        get "/s/#{submitter.slug}/video_kyc"
        expect(response).to have_http_status(:unprocessable_content)

        expect { post "/s/#{submitter.slug}/video_kyc" }
          .not_to(change(SubmissionEvent, :count))
        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end

  describe 'GET /p/:slug (signature pad)' do
    it 'renders while the link is open' do
      get "/p/#{submitter.slug}"

      expect(response).to have_http_status(:ok)
    end

    close_states.each do |name, close|
      it "redirects away when the link is #{name}" do
        close.call(self)

        get "/p/#{submitter.slug}"

        expect(response).to have_http_status(:redirect)
        expect(response.location).to match(%r{/s/#{submitter.slug}})
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Inventory: every route that takes a submitter slug, and where its state check
  # lives. A new route that is not in this list should be added with its check.
  #
  #   GET  /s/:slug                         SubmitFormController#show        completed, archived, expired, declined, 2FA, order
  #   PUT  /s/:slug                         SubmitFormController#update      completed, archived (+account), expired, declined, viewer, 2FA
  #   GET  /s/:slug/completed, /delegated   SubmitFormController             completed page by design; delegated page by design
  #   GET  /s/:slug/values                  SubmitFormValuesController       completed, declined, archived, expired
  #   GET  /s/:slug/download                SubmitFormDownloadController     completed, declined, archived, expired
  #   GET  /s/:slug/documents, /submitters/:slug/download
  #                                         SubmitFormCompletedDownloadController   requires completed (the reverse check)
  #   POST /s/:slug/decline, /delegate      SubmitForm{Decline,Delegate}     declined, completed, archived, expired, viewer
  #   POST /s/:slug/invite                  SubmitFormInviteController       same set via can_invite?
  #   POST /s/:slug/voice_signature         SubmitFormVoiceSignatureController   FormState (this change)
  #   GET/POST /s/:slug/video_kyc           SubmitFormVideoKycController    FormState (this change)
  #   GET  /s/:slug/metadata                SubmitFormMetadataController     all states plus account
  #   POST /s/:slug/upload                  SubmitFormUploadController       completed, declined, archived, expired
  #   POST /s/:slug/prefill_attachments     SubmitFormPrefillAttachmentsController   same set
  #   POST /s/:slug/view, /click_email      SubmitForm{View,ClickEmail}      signed token required; record an event only
  #   GET  /p/:slug                         SubmitFormDrawSignatureController    FormState (this change)
  #   GET  /embed/form/:slug                EmbedFormController              FormState and AuthorizedForForm (this change)
  #   POST /submit_form_email_2fa           SubmitFormEmail2fasController    sends a one-time code only; rate limited
  #   /d/:slug (template link)              StartFormController              template shared-link checks, creates a new submitter
  #   GET  /e/:slug (submission preview)    SubmissionsPreviewController     shows completed documents by design
  # ---------------------------------------------------------------------------
end
