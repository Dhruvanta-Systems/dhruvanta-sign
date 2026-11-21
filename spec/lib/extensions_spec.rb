# frozen_string_literal: true

require 'rails_helper'

describe Extensions do
  describe 'ports' do
    it 'answers every port with a stock default when nothing is registered' do
      described_class::PORTS.each_key do |port|
        expect(described_class.public_send(port)).not_to be_nil
        expect(described_class.registered?(port)).to be(false)
      end
    end

    it 'has stock defaults that leave the app as upstream: no plan features, no limits, no events' do
      plan = described_class.plan_for(create(:account))

      expect(plan.features).to be_empty
      expect(plan.limits).to be_empty
      expect(described_class.feature?(create(:account), 'analytics')).to be(false)
      expect(described_class.within_limit?(create(:account), :docs)).to be(true)
      expect(described_class.emit('submission.created', {})).to be_nil
    end

    it 'refuses to use the stock notifier, otp provider and payment step provider' do
      expect { described_class.notifier.deliver(channel: :email) }.to raise_error(described_class::NotConfigured)
      expect { described_class.otp.verify(subject: 'a', code: '1', purpose: 'p') }
        .to raise_error(described_class::NotConfigured)
      expect { described_class.payment_step.create(nil, nil) }.to raise_error(described_class::NotConfigured)
    end

    it 'accepts the short and the interface names' do
      fake = Fakes::PlanProvider.new

      described_class.register(:plan_provider, fake)

      expect(described_class.plan).to be(fake)
      expect(described_class.registered?(:plan)).to be(true)
      expect { described_class.register(:nope, fake) }.to raise_error(ArgumentError, /unknown extension port/)
    end
  end

  describe '.require!' do
    it 'raises MissingPorts naming every port that is not configured' do
      described_class.register(:notifier, Fakes::Notifier.new)

      expect { described_class.require!(:notifier, :otp, :plan, :storage) }
        .to raise_error(described_class::MissingPorts) { |error| expect(error.ports).to include(:otp, :plan) }
    end

    it 'passes when every named port is configured' do
      described_class.register(:notifier, Fakes::Notifier.new)
      described_class.register(:otp, Fakes::OtpProvider.new)

      expect(described_class.require!(:notifier, :otp)).to be(true)
    end

    it 'counts the HTTP service as configuring a port only when it is enabled for that port' do
      with_env('PREMIUM_SERVICE_URL' => 'https://ext.example.test', 'EXTENSIONS_HTTP_PORTS' => 'plan') do
        expect(described_class.configured?(:plan)).to be(true)
        expect(described_class.configured?(:notifier)).to be(false)
      end

      with_env('PREMIUM_SERVICE_URL' => 'https://ext.example.test', 'EXTENSIONS_HTTP_PORTS' => 'plan,notifier,otp') do
        expect(described_class.configured?(:notifier)).to be(true)
        expect(described_class.configured?(:otp)).to be(true)
      end
    end

    it 'treats local disk storage as not configured and an object store as configured' do
      allow(Rails.application.config.active_storage).to receive(:service).and_return(:disk)
      expect(described_class.configured?(:storage)).to be(false)

      allow(Rails.application.config.active_storage).to receive(:service).and_return(:aws_s3)
      expect(described_class.configured?(:storage)).to be(true)
    end
  end

  describe '.emit' do
    it 'passes the event to the sink and never raises into the request' do
      sink = Fakes::EventSink.new
      described_class.register(:event_sink, sink)

      described_class.emit('template.created', { template_id: 1 })

      expect(sink.names).to eq(['template.created'])

      allow(sink).to receive(:emit).and_raise(StandardError, 'down')
      expect { described_class.emit('template.created', {}) }.not_to raise_error
    end

    it 'is called for submissions, templates and users when they are created' do
      sink = Fakes::EventSink.new
      described_class.register(:event_sink, sink)

      user = create(:user)
      create(:template, account: user.account, author: user)

      expect(sink.names).to include('user.created', 'template.created')
    end
  end

  describe 'the HTTP implementation (PremiumBridge)' do
    around do |example|
      with_env('PREMIUM_SERVICE_URL' => 'https://ext.example.test', 'PREMIUM_API_TOKEN' => 'token') { example.run }
    end

    before do
      PremiumBridge.instance_variable_set(:@connection, nil)
      PremiumBridge.instance_variable_set(:@failure_count, 0)
      PremiumBridge.instance_variable_set(:@circuit_open_at, nil)
    end

    it 'supplies plan, events and verification by default' do
      expect(described_class.plan).to be_a(described_class::Http::Plan)
      expect(described_class.event_sink).to be_a(described_class::Http::EventSink)
      expect(described_class.verification).to be_a(described_class::Http::Verification)
      expect(described_class.notifier).to be_a(described_class::Stock::Notifier)
    end

    it 'sends submitter.completed under the name older servers know' do
      stub = stub_request(:post, 'https://ext.example.test/api/hooks/form.completed').to_return(status: 204)

      described_class.emit('submitter.completed', { submitter_id: 7 })

      expect(stub).to have_been_requested
    end

    it 'posts a notification with attachments as base64' do
      with_env('EXTENSIONS_HTTP_PORTS' => 'notifier') do
        stub = stub_request(:post, 'https://ext.example.test/api/notifications')
               .with { |req| JSON.parse(req.body).dig('attachments', 0, 'content_base64') == Base64.strict_encode64('pdf') }
               .to_return(status: 200, body: '{"status":"queued"}')

        described_class.notifier.deliver(channel: :email, to: ['a@example.test'],
                                         attachments: [{ filename: 'a.pdf', content: 'pdf' }])

        expect(stub).to have_been_requested
      end
    end
  end
end
