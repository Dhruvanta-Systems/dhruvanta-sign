# frozen_string_literal: true

module Submissions
  module CreateFromSpreadsheet
    MAX_ROWS = 1000

    module_function

    def call(template:, user:, file:, params: {})
      rows = parse_file(file)
      raise ArgumentError, "Too many rows (max #{MAX_ROWS})" if rows.size > MAX_ROWS

      submissions = []
      errors = []
      rows.each_with_index do |row, index|
        email = (row['email'] || row['Email'] || row['EMAIL'])&.to_s&.strip
        if email.blank? || !email.match?(User::EMAIL_REGEXP)
          errors << { row: index + 2, error: 'Missing or invalid email' }
          next
        end
        name = (row['name'] || row['Name'] || row['NAME'])&.to_s&.strip.presence
        phone = (row['phone'] || row['Phone'] || row['PHONE'])&.to_s&.strip.presence
        begin
          created = Submissions.create_from_emails(template:, user:, source: :bulk, emails: [email],
                                                   mark_as_sent: params[:send_email] != false, params:)
          sub = created.first
          sub.submitters.first&.update!(name:, phone:) if name || phone
          submissions << sub
        rescue StandardError => e
          errors << { row: index + 2, error: e.message.truncate(100) }
        end
      end
      { submissions:, errors:, total: rows.size }
    end

    def parse_file(file)
      case File.extname(file.original_filename).downcase
      when '.csv'
        require 'csv'
        CSV.parse(file.read.force_encoding('UTF-8'), headers: true).map(&:to_h)
      when '.xlsx'
        require 'rubyXL'
        workbook = RubyXL::Parser.parse_buffer(file.read)
        sheet = workbook[0]
        headers = sheet[0]&.cells&.map { |c| c&.value&.to_s&.strip }
        return [] if headers.blank?

        sheet.drop(1).filter_map do |row|
          if row.nil?
            nil
          else
            headers.zip(row.cells.map do |c|
              c&.value&.to_s&.strip
            end).to_h
          end
        end
      else
        raise ArgumentError, 'Unsupported file format. Use CSV or XLSX.'
      end
    end
  end
end
