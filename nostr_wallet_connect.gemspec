# frozen_string_literal: true

require_relative 'lib/nostr_wallet_connect/version'

Gem::Specification.new do |spec|
  spec.name        = 'nwc-ruby'
  spec.version     = NostrWalletConnect::VERSION
  spec.authors     = ['MegalithicBTC']
  spec.email       = ['hello@megalithic.me']

  spec.summary     = 'Ruby client for Nostr Wallet Connect (NIP-47) with safe long-running relay connections.'
  spec.description = <<~DESC
    A production-grade Ruby client for Nostr Wallet Connect (NIP-47). Handles the Nostr
    protocol, NIP-04 and NIP-44 v2 encryption, secp256k1 key derivation, Schnorr signing,
    and — most importantly — a reliable long-running WebSocket connection to the relay
    with heartbeat, pong deadline, forced recycle, exponential backoff, and SIGTERM
    handling. Developers call `pay_invoice`, `make_invoice`, `lookup_invoice`, etc. and
    `subscribe_to_notifications { |n| ... }` — the transport reliability is hidden.
  DESC

  spec.homepage              = 'https://github.com/MegalithicBTC/nwc-ruby'
  spec.license               = 'MIT'
  spec.required_ruby_version = '>= 3.2.0'

  spec.metadata['homepage_uri']          = spec.homepage
  spec.metadata['source_code_uri']       = spec.homepage
  spec.metadata['bug_tracker_uri']       = "#{spec.homepage}/issues"
  spec.metadata['changelog_uri']         = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir[
    'lib/**/*.rb',
    'README.md',
    'LICENSE',
    'CHANGELOG.md',
    'nostr_wallet_connect.gemspec'
  ]
  spec.require_paths = ['lib']

  spec.add_dependency 'async', '~> 2.10'
  spec.add_dependency 'async-http', '~> 0.70'
  spec.add_dependency 'async-websocket', '~> 0.26'
  spec.add_dependency 'base64'
  spec.add_dependency 'ecdsa', '~> 1.2'
  spec.add_dependency 'logger'
  spec.add_dependency 'rbsecp256k1', '~> 6.0'

  spec.add_development_dependency 'rake',    '~> 13.0'
  spec.add_development_dependency 'rspec',   '~> 3.13'
  spec.add_development_dependency 'rubocop', '~> 1.60'
  spec.add_development_dependency 'webmock', '~> 3.20'
end
