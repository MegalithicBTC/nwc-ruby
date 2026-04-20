# frozen_string_literal: true

require "secp256k1"

module NostrWalletConnect
  module Crypto
    # BIP-340 Schnorr signatures for Nostr events.
    #
    # Nostr event IDs are 32-byte SHA-256 hashes. The event signature is a
    # 64-byte BIP-340 Schnorr signature over that hash, verifiable against the
    # event's 32-byte x-only public key.
    module Schnorr
      module_function

      # Sign a 32-byte digest with a private key. Returns 64-byte signature
      # as a lowercase hex string (128 chars).
      def sign(digest_bytes, privkey_hex)
        raise ArgumentError, "digest must be 32 bytes" unless digest_bytes.bytesize == 32

        ctx = ::Secp256k1::Context.create
        kp  = ctx.key_pair_from_private_key(Keys.hex_to_bytes(privkey_hex))
        sig = ctx.sign_schnorr(kp, digest_bytes)
        Keys.bytes_to_hex(sig.serialized)
      end

      # Verify a 64-byte Schnorr signature. Returns true / false.
      def verify(digest_bytes, sig_hex, xonly_pubkey_hex)
        return false unless sig_hex.is_a?(String) && sig_hex.length == 128

        ctx = ::Secp256k1::Context.create
        # rbsecp256k1 wants a 32-byte "x-only" pubkey object.
        xonly_pub = ctx.x_only_public_key_from_bytes(Keys.hex_to_bytes(xonly_pubkey_hex))
        sig_obj   = ::Secp256k1::SchnorrSignature.from_data(Keys.hex_to_bytes(sig_hex))
        ctx.verify_schnorr(sig_obj, xonly_pub, digest_bytes)
      rescue ::Secp256k1::Error, ArgumentError
        false
      end
    end
  end
end
