# frozen_string_literal: true

ActiveSupport.on_load(:active_storage_attachment) do
  attribute :uuid, :string, default: -> { SecureRandom.uuid }

  has_many_attached :preview_images

  def self.service_url_time
    return unless Docuseal.multitenant?

    now = Time.current

    now.min < 30 ? now.beginning_of_hour : now.beginning_of_hour + 30.minutes
  end

  def signed_uuid
    @signed_uuid ||= ApplicationRecord.signed_id_verifier.generate(uuid, expires_in: 6.hours, purpose: :attachment)
  end

  def signed_key
    @signed_key ||= ApplicationRecord.signed_id_verifier.generate([id, uuid], expires_in: 6.hours, purpose: :attachment)
  end
end

ActiveSupport.on_load(:active_storage_blob) do
  attribute :uuid, :string, default: -> { SecureRandom.uuid }
  attribute :io_data, :string, default: ''

  def self.proxy_url(blob, expires_at: nil, filename: nil, host: nil)
    Rails.application.routes.url_helpers.blobs_proxy_url(
      signed_uuid: blob.signed_uuid(expires_at:), filename: FilenameUtils.url_filename(filename || blob.filename),
      **Docuseal.default_url_options,
      **{ host: }.compact
    )
  end

  def self.proxy_path(blob, expires_at: nil, filename: nil)
    Rails.application.routes.url_helpers.blobs_proxy_path(
      signed_uuid: blob.signed_uuid(expires_at:), filename: FilenameUtils.url_filename(filename || blob.filename)
    )
  end

  def uuid
    super || begin
      new_uuid = SecureRandom.uuid
      update_columns(uuid: new_uuid)
      new_uuid
    end
  end

  def signed_uuid(expires_at: nil)
    expires_at = expires_at.to_i if expires_at

    ApplicationRecord.signed_id_verifier.generate([uuid, 'blob', expires_at].compact)
  end

  def delete
    service.delete(key)
  end
end

# /disk/:key/*filename URLs: in hosted mode the filename in the URL path is the ASCII
# slug. The signed key still carries the real name in its Content-Disposition, so
# the download keeps it (see FilenameUtils.url_filename).
module HostedDiskUrlFilename
  class Helpers < SimpleDelegator
    def rails_disk_service_url(key, filename:, **)
      __getobj__.rails_disk_service_url(key, filename: FilenameUtils.url_filename(filename), **)
    end
  end

  private

  def url_helpers
    Helpers.new(super)
  end
end

require 'active_storage/service/disk_service'

ActiveStorage::Service::DiskService.prepend(HostedDiskUrlFilename)

ActiveStorage::LogSubscriber.detach_from(:active_storage) if Rails.env.production?

Rails.configuration.to_prepare do
  ActiveStorage::DiskController.after_action(only: :show) do
    response.set_header('cache-control', 'public, max-age=31536000')
  end

  LoadActiveStorageConfigs.call
rescue StandardError => e
  Rails.logger.error(e) unless Rails.env.production?

  nil
end
