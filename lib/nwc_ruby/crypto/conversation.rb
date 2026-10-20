# frozen_string_literal: true

module NwcRuby
  module Crypto
    # The symmetric keys for one (our private key, their public key) pair.
    #
    # NIP-04 and NIP-44 v2 both start from the same ECDH, which is the slow
    # step here (pure-Ruby scalar multiplication, tens of milliseconds) and
    # depends only on the two keys. This object runs it once, on first use,
    # and keeps the result. Per-message randomness is unaffected: NIP-44 still
    # draws a fresh nonce and NIP-04 a fresh IV on every encrypt.
    #
    # Nothing is computed in `initialize`, so a bad key raises at first use,
    # exactly where the uncached path raises it, and a failure is not cached.
    class Conversation
      def initialize(privkey_hex, pubkey_hex)
        @privkey_hex = privkey_hex
        @pubkey_hex  = pubkey_hex
      end

      # NIP-04's AES-256 key: the raw shared X coordinate.
      def nip04_key
        @nip04_key ||= ECDH.shared_x(@privkey_hex, @pubkey_hex)
      end

      # NIP-44 v2's conversation key: HKDF-extract over the same shared X.
      def nip44_key
        @nip44_key ||= NIP44::Cipher.hkdf_extract(NIP44::Cipher::SALT.b, nip04_key)
      end
    end
  end
end
