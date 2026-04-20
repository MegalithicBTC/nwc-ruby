# frozen_string_literal: true

require "secp256k1"
require "ecdsa"

module NostrWalletConnect
  module Crypto
    # ECDH for Nostr: compute the shared secret between our private key and
    # their x-only public key.
    #
    # CRITICAL: Nostr ECDH returns the **X coordinate of the shared point only**
    # (32 bytes). This differs from libsecp256k1's default `ecdh()` function,
    # which returns SHA256(compressed_point). We have to do the multiplication
    # ourselves using the `ecdsa` gem.
    #
    # This is used by both NIP-04 (as the AES key directly) and NIP-44 v2 (as
    # the IKM for HKDF).
    module ECDH
      module_function

      GROUP = ::ECDSA::Group::Secp256k1

      # Returns the raw 32-byte X coordinate of the shared point.
      #
      # @param privkey_hex [String] our 32-byte private key (hex)
      # @param xonly_pubkey_hex [String] their 32-byte x-only public key (hex)
      # @return [String] 32 raw bytes (binary-encoded)
      def shared_x(privkey_hex, xonly_pubkey_hex)
        Keys.validate_hex32!(privkey_hex, "private key")
        Keys.validate_hex32!(xonly_pubkey_hex, "public key")

        # BIP-340 x-only pubkeys always correspond to the even-Y lifted point.
        pubkey_point = lift_x(Keys.hex_to_bytes(xonly_pubkey_hex).unpack1("H*").to_i(16))
        priv_int     = privkey_hex.to_i(16)

        shared_point = pubkey_point.multiply_by_scalar(priv_int)
        [shared_point.x.to_s(16).rjust(64, "0")].pack("H*")
      end

      # BIP-340 "lift_x": given an x coordinate, return the point with even Y.
      def lift_x(x)
        raise EncryptionError, "x out of range" if x.zero? || x >= GROUP.field.prime

        p   = GROUP.field.prime
        c   = (x.pow(3, p) + 7) % p
        y   = c.pow((p + 1) / 4, p)
        raise EncryptionError, "x is not on the curve" unless y.pow(2, p) == c

        y = p - y if y.odd?
        GROUP.new_point([x, y])
      end
    end
  end
end
