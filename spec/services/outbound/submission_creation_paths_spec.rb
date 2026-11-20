# frozen_string_literal: true

require 'rails_helper'

# Every submission creation path emits the `submission_created` outbox event.
RSpec.describe 'Submission creation paths emit submission_created' do
  let(:account)  { create(:account) }
  let(:user)     { create(:user, account:) }
  let(:template) { create(:template, account:, author: user) }

  before do
    allow(Outbound::WebhooksDispatcher).to receive(:dispatch)
      .and_return(Outbound::WebhooksDispatcher::DispatchResult.ok(200))
  end

  def submission_created_rows
    WebhookOutbox.where(event_type: WebhookOutbox::EVENT_SUBMISSION_CREATED)
  end

  it 'fires once on a direct `template.submissions.new(...).save!`' do
    expect do
      submission = template.submissions.new(
        created_by_user: user,
        account_id: account.id,
        source: :api,
        template_submitters: template.submitters,
        template_fields: template.fields,
        template_schema: template.schema
      )
      submission.save!
    end.to change { submission_created_rows.count }.by(1)
  end

  it 'fires once via `Submissions.create_from_emails` (invite/bulk path)' do
    expect do
      Submissions.create_from_emails(
        template:, user:, source: :invite,
        emails: ['alice@example.com'],
        params: { 'send_email' => false }
      )
    end.to change { submission_created_rows.count }.by(1)
  end

  it 'fires once per submission via `Submissions::CreateFromSubmitters.call` (API/MCP path)' do
    submissions_attrs = [
      { submitters: [{ email: 'bob@example.com', uuid: template.submitters.first['uuid'] }] }
    ]

    expect do
      Submissions::CreateFromSubmitters.call(
        template:, user:, source: :api,
        submissions_attrs:,
        submitters_order: 'preserved',
        params: {}
      )
    end.to change { submission_created_rows.count }.by(1)
  end

  it 'fires N times for N submissions in `CreateFromSubmitters.call` (per-row not per-batch)' do
    submissions_attrs = [
      { submitters: [{ email: 'c1@example.com', uuid: template.submitters.first['uuid'] }] },
      { submitters: [{ email: 'c2@example.com', uuid: template.submitters.first['uuid'] }] }
    ]

    expect do
      Submissions::CreateFromSubmitters.call(
        template:, user:, source: :api,
        submissions_attrs:,
        submitters_order: 'preserved',
        params: {}
      )
    end.to change { submission_created_rows.count }.by(2)
  end

  it 'fires once via the resubmit-controller shape (`account.submissions.new.save!`)' do
    expect do
      submission = account.submissions.new(
        created_by_user: user,
        account_id: account.id,
        source: :link,
        submitters_order: :preserved,
        template_id: template.id,
        template_fields: template.fields,
        template_schema: template.schema,
        template_submitters: template.submitters
      )
      submission.save!
    end.to change { submission_created_rows.count }.by(1)
  end

  it 'fires once via the embedded start_form shape (`template.submissions.new` then save)' do
    expect do
      submission = template.submissions.new(
        account_id: template.account_id,
        source: :link,
        template_submitters: template.submitters,
        template_fields: template.fields,
        template_schema: template.schema
      )
      submission.save!
    end.to change { submission_created_rows.count }.by(1)
  end

  it 'fires only on :create (NOT on subsequent updates) — model lifecycle guarantee' do
    submission = create(:submission, template:, created_by_user: user)
    baseline = submission_created_rows.count

    submission.update!(name: 'renamed-after-create')

    expect(submission_created_rows.count).to eq(baseline)
  end
end
