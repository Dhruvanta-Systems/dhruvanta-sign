# frozen_string_literal: true

class EmbedFormController < ActionController::Base
  layout 'embed'

  def show
    @submitter = Submitter.find_by!(slug: params[:slug])
    @submission = @submitter.submission
    @attachments_index = ActiveStorage::Attachment.where(record: @submitter,
                                                         name: :attachments).preload(:blob).index_by(&:uuid)
    @form_configs = Submitters::FormConfigs.call(@submitter)
    Submissions.preload_with_pages(@submission)
  rescue ActiveRecord::RecordNotFound
    render plain: 'Not found', status: :not_found
  end
end
