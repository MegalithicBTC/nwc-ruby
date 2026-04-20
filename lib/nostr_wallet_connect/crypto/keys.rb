# frozen_string_literal: true

require "rbsecp256k1"

module NostrWalletConnect
  module Crypto
    # Key helpers: hex <-> bytes, private key -> x-only pubkey, validation.
    #
    # Nostr uses BIP-340 Schnorr signatures over secp256k1. Public keys are
    # "x-only" — just the 32-byte X coordinate. We use rbsecp256k1 (which wraps
    # libsecp256k1) to derive them correctly.
    module Keys
      module_function

      # Generate a new 32-byte private key as a lowercase hex string.
      def generate_private_key
        SecureRandom.bytes(32).unpack1("H*")
      end

      # Derive the 32-byte x-only public key (hex) from a private key (hex).
      def public_key_from_private(privkey_hex)
        validate_hex32!(privkey_hex, "private key")
        ctx = ::Secp256k1::Context.create
        kp  = ctx.key_pair_from_private_key(hex_to_bytes(privkey_hex))
        # rbsecp256k1 gives us a compressed public key (33 bytes, 02/03 prefix).
        # X-only pubkey is just bytes 1..32.
        compressed = kp.public_key.compressed
        bytes_to_hex(compressed[1, 32])
      end

      def hex_to_bytes(hex)
        [hex].pack("H*")
      end

      def bytes_to_hex(bytes)
        bytes.unpack1("H*")
      end

      def validate_hex32!(hex, label = "value")
        unless hex.is_a?(String) && hex.match?(/\A[0-9a-fA-F]{64}\z/)
          raise Error, "#{label} must be 64 hex characters (32 bytes)"
        end
      end
    end
  end
end
