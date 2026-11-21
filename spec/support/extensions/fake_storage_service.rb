# frozen_string_literal: true

# Reference fake of the storage_service port: it names the Active Storage service
# (from config/storage.yml) that holds files.
#
#   name -> :aws_s3 / :google / :azure / any service you define
module Fakes
  class StorageService
    def initialize(name = :aws_s3)
      @name = name
    end

    attr_reader :name
  end
end
