# frozen_string_literal: true

require 'rails_helper'

# Source-inspection spec for `lib/puma/plugin/sidekiq_embed.rb`.
#
# The plugin is created via `Puma::Plugin.create do ... end`, which
# returns an anonymous subclass and is only invoked when Puma
# instantiates the plugin during boot — there is no exposed class to
# instantiate from a unit test. Refactoring the plugin into a
# testable class is out of scope here.
#
# Instead this spec asserts the gate's *static* shape by reading the
# plugin source. That covers the three cases from the brief by
# guaranteeing the implementation is the same `LOCAL_REDIS_URL`
# empty-gate as `redis_server.rb`:
#
#   1. LOCAL_REDIS_URL empty + MULTITENANT != 'true'
#      → embedded Sidekiq DOES NOT activate (early return).
#      Operator has wired external Redis; the dedicated `sidekiq`
#      worker container is the sole worker.
#   2. LOCAL_REDIS_URL set + MULTITENANT != 'true'
#      → embedded Sidekiq activates (proceeds past the gate).
#      Default DocuSeal install: `config/dotenv.rb` synthesizes
#      LOCAL_REDIS_URL alongside the in-Puma forked redis-server.
#   3. MULTITENANT == 'true'
#      → embedded Sidekiq does not activate. This case is gated
#      one level up in `config/puma.rb` via `if ENV['MULTITENANT']
#      != 'true' || ENV['DEMO'] == 'true'` around the
#      `require_relative` + `plugin :sidekiq_embed` lines, so the
#      plugin file is never even loaded.
describe 'lib/puma/plugin/sidekiq_embed.rb gate' do
  let(:plugin_path) do
    Rails.root.join('lib/puma/plugin/sidekiq_embed.rb')
  end
  let(:redis_server_path) do
    Rails.root.join('lib/puma/plugin/redis_server.rb')
  end
  let(:plugin_source) { File.read(plugin_path) }
  let(:redis_server_source) { File.read(redis_server_path) }

  it 'gates on LOCAL_REDIS_URL — early returns when empty' do
    # Mirrors redis_server.rb's gate shape exactly per L_SSSSSSS-5.
    expect(plugin_source).to include(
      "return if ENV['LOCAL_REDIS_URL'].to_s.empty?"
    )
  end

  it 'guards both plugin entry points (config + start)' do
    # The Puma plugin DSL invokes both `config(cfg)` (worker mode) and
    # `start(launcher)` (single mode); both need the same gate so the
    # embedded Sidekiq disappears symmetrically.
    config_block = plugin_source.split('def config(cfg)', 2).last.split('def start(launcher)', 2).first
    start_block  = plugin_source.split('def start(launcher)', 2).last.split('def fire_event', 2).first

    expect(config_block).to include("return if ENV['LOCAL_REDIS_URL'].to_s.empty?")
    expect(start_block).to include("return if ENV['LOCAL_REDIS_URL'].to_s.empty?")
  end

  it 'mirrors redis_server.rb’s LOCAL_REDIS_URL empty-gate exactly' do
    # Symmetry guarantee: when the operator wires external Redis
    # (LOCAL_REDIS_URL empty), BOTH embed plugins disable together.
    redis_server_gate = redis_server_source.match(
      /return if ENV\['LOCAL_REDIS_URL'\]\.to_s\.empty\?/
    )
    expect(redis_server_gate).not_to be_nil

    expect(plugin_source).to include(redis_server_gate.to_s)
  end
end
