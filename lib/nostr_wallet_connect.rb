# frozen_string_literal: true

require 'json'
require 'base64'
require 'securerandom'
require 'openssl'
require 'uri'
require 'logger'

require_relative 'nostr_wallet_connect/version'
require_relative 'nostr_wallet_connect/errors'
require_relative 'nostr_wallet_connect/crypto/keys'
require_relative 'nostr_wallet_connect/crypto/schnorr'
require_relative 'nostr_wallet_connect/crypto/ecdh'
require_relative 'nostr_wallet_connect/nip04/cipher'
require_relative 'nostr_wallet_connect/nip44/cipher'
require_relative 'nostr_wallet_connect/event'
require_relative 'nostr_wallet_connect/connection_string'
require_relative 'nostr_wallet_connect/nip47/methods'
require_relative 'nostr_wallet_connect/nip47/request'
require_relative 'nostr_wallet_connect/nip47/response'
require_relative 'nostr_wallet_connect/nip47/notification'
require_relative 'nostr_wallet_connect/nip47/info'
require_relative 'nostr_wallet_connect/transport/relay_connection'
require_relative 'nostr_wallet_connect/client'
require_relative 'nostr_wallet_connect/test_runner'

# NostrWalletConnect is a Ruby client for NIP-47 (Nostr Wallet Connect).
#
# Quick start:
#
#   client = NostrWalletConnect::Client.from_uri(ENV["NWC_URL"])
#   invoice = client.make_invoice(amount: 1_000) # msats
#   puts invoice["invoice"]
#
#   client.subscribe_to_notifications do |n|
#     puts "Got paid: #{n['amount']} msats for #{n['payment_hash']}"
#   end
#
# To exercise a connection string end-to-end (from IRB, a Rails console, a
# spec, or a rake task in your own app), use the top-level test method:
#
#   NostrWalletConnect.test(
#     nwc_url: ENV["NWC_URL"],
#     pay_to_lightning_address: "you@getalby.com", # optional — only used for write tests
#     pay_to_satoshis_amount: 10                    # used for both outbound and inbound tests
#   )
#
# Returns true if every check passed, false otherwise. Output is streamed to
# $stdout by default; pass `output: some_io` to redirect.
module NostrWalletConnect
  # Convenience wrapper around TestRunner. See TestRunner for option docs.
  #
  # @return [Boolean] true if all checks passed, false otherwise.
  def self.test(nwc_url:,
                pay_to_lightning_address: nil,
                pay_to_satoshis_amount: TestRunner::DEFAULT_SATOSHIS,
                output: $stdout)
    TestRunner.new(
      nwc_url: nwc_url,
      pay_to_lightning_address: pay_to_lightning_address,
      pay_to_satoshis_amount: pay_to_satoshis_amount,
      output: output
    ).run
  end
end
