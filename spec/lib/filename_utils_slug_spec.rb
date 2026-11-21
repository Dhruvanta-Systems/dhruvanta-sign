# frozen_string_literal: true

require 'rails_helper'

describe FilenameUtils do
  describe '.ascii_slug' do
    {
      'My Contract.pdf' => 'my-contract.pdf',
      'Résumé Ünïcode.PDF' => 'resume-unicode.pdf',
      'ఒప్పందం పత్రం.pdf' => 'file.pdf', # Telugu
      'अनुबंध दस्तावेज़.pdf' => 'file.pdf', # Hindi
      'ఒప్పందం contract final.pdf' => 'contract-final.pdf', # script mixed with Latin
      '📄 Plan 🚀.pdf' => 'plan.pdf', # emoji
      '🙂.pdf' => 'file.pdf',
      '★★★ !!! ###.pdf' => 'file.pdf', # nothing but symbols
      '***' => 'file',
      '' => 'file',
      '   .pdf' => 'file.pdf',
      'report..final (1).pdf' => 'report.final-1.pdf',
      'a   b---c.txt' => 'a-b-c.txt',
      '../../etc/passwd' => 'passwd',
      'C:\\Users\\me\\Doc 1.pdf' => 'doc-1.pdf',
      '.hidden' => 'hidden',
      'archive.tar.gz' => 'archive.tar.gz',
      'UPPER_case-Name.DOCX' => 'upper_case-name.docx'
    }.each do |input, expected|
      it "turns #{input.inspect} into #{expected.inspect}" do
        expect(described_class.ascii_slug(input)).to eq(expected)
      end
    end

    it 'only ever produces [a-z0-9._-] and never an empty name' do
      ['ఒప్పందం', '🙂🙂', '%2e%2e', "tab\tname\n.pdf", "nul\u0000.pdf", 'ÄÖÜ.pdf', '日本語.pdf'].each do |input|
        slug = described_class.ascii_slug(input)

        expect(slug).to match(/\A[a-z0-9._-]+\z/)
        expect(slug).not_to start_with('.')
      end
    end

    it 'accepts an ActiveStorage::Filename' do
      expect(described_class.ascii_slug(ActiveStorage::Filename.new('My Contract.pdf'))).to eq('my-contract.pdf')
    end
  end

  describe '.url_filename' do
    it 'is the slug in hosted mode' do
      with_env('HOSTED_MODE' => 'true') { expect(described_class.url_filename('My Contract.pdf')).to eq('my-contract.pdf') }
    end

    it 'leaves the name unchanged outside hosted mode' do
      expect(described_class.url_filename('My Contract.pdf')).to eq('My Contract.pdf')
    end
  end
end
