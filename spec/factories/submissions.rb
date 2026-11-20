# frozen_string_literal: true

FactoryBot.define do
  factory :submission do
    template
    created_by_user factory: %i[user]

    before(:create) do |submission, _|
      submission.account_id = submission.template.account_id
      submission.template_fields = submission.template.fields
      submission.template_schema = submission.template.schema
      submission.template_submitters = submission.template.submitters
    end

    # Submitters must be built BEFORE the submission is saved so they are
    # persisted in the same transaction. The `after_commit on: :create` webhook
    # emitter then sees them, exactly as in production; building them in
    # after(:create) made the emitter observe an empty submitters list.
    trait :with_submitters do
      before(:create) do |submission, _|
        submission.template.submitters.each do |template_submitter|
          submission.submitters.build(account_id: submission.template.account_id,
                                      uuid: template_submitter['uuid'],
                                      email: Faker::Internet.email,
                                      name: Faker::Name.name)
        end
      end
    end

    trait :with_events do
      after(:create) do |submission, _|
        submission.submitters.each do |submitter|
          create(:submission_event, submission:, submitter:)
        end
      end
    end
  end
end
