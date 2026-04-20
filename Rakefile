# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:spec)
task default: :spec

namespace :nwc do
  desc <<~DESC
    Diagnose an NWC connection string end-to-end.

    Reads from environment variables (never hard-coded):
      NWC_URL                  – required, the nostr+walletconnect:// URI
      PAY_TO_LIGHTNING_ADDRESS – optional, only needed for write tests
      PAY_TO_SATOSHIS_AMOUNT   – optional, defaults to 100

    Examples:
      rake nwc:test                                          # uses env vars
      NWC_URL="nostr+walletconnect://..." rake nwc:test
      rake 'nwc:test'  PAY_TO_LIGHTNING_ADDRESS=you@example.com PAY_TO_SATOSHIS_AMOUNT=10
  DESC
  task :test do
    require 'nwc_ruby'

    nwc_url = ENV.fetch('NWC_URL') do
      abort "ERROR: NWC_URL env var is required.\n" \
            "  NWC_URL=\"nostr+walletconnect://...\" rake nwc:test"
    end

    ok = NwcRuby.test(
      nwc_url:                  nwc_url,
      pay_to_lightning_address: ENV['PAY_TO_LIGHTNING_ADDRESS'],
      pay_to_satoshis_amount:   Integer(ENV.fetch('PAY_TO_SATOSHIS_AMOUNT', 100))
    )

    exit(ok ? 0 : 1)
  end
end
