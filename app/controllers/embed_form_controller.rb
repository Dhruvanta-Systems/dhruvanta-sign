# frozen_string_literal: true

class EmbedFormController < ApplicationController
  layout 'embed'

  # Same public, slug-keyed access as the signer page. Deriving from
  # ApplicationController (instead of ActionController::Base) also gives the
  # shared form view its helpers; without them the embedded form failed to render.
  skip_before_action :authenticate_user!
  skip_before_action :maybe_redirect_to_setup
  skip_authorization_check

  def show
    @submitter = Submitter.find_by!(slug: params[:slug])
    @submission = @submitter.submission

    # The embed is the signer page without its own 2FA or locked-state screens, so
    # it applies the same rules as SubmitFormController#show and refuses instead of
    # rendering: a closed link answers 410, a link the visitor may not use yet 403.
    if (reason = Submitters::FormState.locked_reason(@submitter))
      return render plain: "This form is not available (#{reason}).", status: :gone
    end

    unless Submitters::AuthorizedForForm.call(@submitter, nil, request, with_order: true)
      return render plain: 'This form is not available.', status: :forbidden
    end

    @attachments_index = ActiveStorage::Attachment.where(record: @submitter,
                                                         name: :attachments).preload(:blob).index_by(&:uuid)
    @form_configs = Submitters::FormConfigs.call(@submitter)
    Submissions.preload_with_pages(@submission)
  rescue ActiveRecord::RecordNotFound
    render plain: 'Not found', status: :not_found
  end
end
