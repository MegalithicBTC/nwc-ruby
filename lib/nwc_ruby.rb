# frozen_string_literal: true

require 'json'
require 'base64'
require 'securerandom'
require 'openssl'
require 'uri'
require 'logger'

require_relative 'nwc_ruby/version'
require_relative 'nwc_ruby/errors'
require_relative 'nwc_ruby/crypto/keys'
require_relative 'nwc_ruby/crypto/schnorr'
require_relative 'nwc_ruby/crypto/ecdh'
require_relative 'nwc_ruby/nip04/cipher'
require_relative 'nwc_ruby/nip44/cipher'
require_relative 'nwc_ruby/event'
require_relative 'nwc_ruby/connection_string'
require_relative 'nwc_ruby/nip47/methods'
require_relative 'nwc_ruby/nip47/request'
require_relative 'nwc_ruby/nip47/response'
require_relative 'nwc_ruby/nip47/notification'
require_relative 'nwc_ruby/nip47/info'
require_relative 'nwc_ruby/transport/relay_connection'
require_relative 'nwc_ruby/client'
require_relative 'nwc_ruby/test_runner'

# NwcRuby is a Ruby client for NIP-47 (Nostr Wallet Connect).
#
# Quick start:
#
#   client = NwcRuby::Client.from_uri(ENV["NWC_URL"])
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
#   NwcRuby.test(
#     nwc_url: ENV["NWC_URL"],
#     pay_to_lightning_address: "you@getalby.com", # optional — only used for write tests
#     pay_to_satoshis_amount: 10                    # used for both outbound and inbound tests
#   )
#
# Returns true if every check passed, false otherwise. Output is streamed to
# $stdout by default; pass `output: some_io` to redirect.
module NwcRuby
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
