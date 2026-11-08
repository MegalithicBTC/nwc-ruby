# frozen_string_literal: true

require 'openssl'

module NwcRuby
  module Crypto
    # ECDH for Nostr: compute the shared secret between our private key and
    # their x-only public key.
    #
    # CRITICAL: Nostr ECDH returns the **X coordinate of the shared point only**
    # (32 bytes). libsecp256k1's `ecdh()` returns SHA256(compressed_point)
    # instead, and rbsecp256k1 hard-codes that hash, so it can't be used here.
    # OpenSSL's ECDH returns the raw X coordinate, left-padded to 32 bytes.
    #
    # This is used by both NIP-04 (as the AES key directly) and NIP-44 v2 (as
    # the IKM for HKDF).
    module ECDH
      module_function

      # secp256k1 field prime and group order (SEC 2, section 2.4.1).
      P = 0xFFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFE_FFFFFC2F
      N = 0xFFFFFFFF_FFFFFFFF_FFFFFFFF_FFFFFFFE_BAAEDCE6_AF48A03B_BFD25E8C_D0364141

      # Numeric OIDs, so nothing depends on OpenSSL's curve-name table.
      SECP256K1_OID = '1.3.132.0.10'
      EC_PUBLIC_KEY_OID = '1.2.840.10045.2.1'

      # X coordinate of the generator G, for the self-test in `available?`.
      GX_HEX = '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798'

      # Returns the raw 32-byte X coordinate of the shared point.
      #
      # @param privkey_hex [String] our 32-byte private key (hex)
      # @param xonly_pubkey_hex [String] their 32-byte x-only public key (hex)
      # @return [String] 32 raw bytes (binary-encoded)
      # @raise [EncryptionError] if either key is out of range or the public
      #   key is not on the curve
      # @raise [CryptoUnavailableError] if this OpenSSL lacks secp256k1
      def shared_x(privkey_hex, xonly_pubkey_hex)
        Keys.validate_hex32!(privkey_hex, 'private key')
        Keys.validate_hex32!(xonly_pubkey_hex, 'public key')

        d = privkey_hex.to_i(16)
        raise EncryptionError, 'private key out of range' if d.zero? || d >= N

        x = xonly_pubkey_hex.to_i(16)
        raise EncryptionError, 'x out of range' if x.zero? || x >= P

        ensure_available!
        derive(Keys.hex_to_bytes(privkey_hex), Keys.hex_to_bytes(xonly_pubkey_hex))
      end

      # Whether this Ruby's OpenSSL can do secp256k1 ECDH. Some builds leave
      # the curve out, and FIPS mode refuses it. Under RHEL 9's FIPS provider
      # the curve's group still loads and only the key operations fail, so
      # this runs a real ECDH with a known answer (1 * G has X coordinate GX)
      # instead of looking the curve up. Checked once per process.
      def available?
        return @available unless @available.nil?

        gx = Keys.hex_to_bytes(GX_HEX)
        @available = begin
          derive(Keys.hex_to_bytes("#{'0' * 63}1"), gx) == gx
        rescue EncryptionError
          false
        end
      end

      def ensure_available!
        return if available?

        reason = if ::OpenSSL.fips_mode
                   'OpenSSL is in FIPS mode, which does not allow it'
                 else
                   'this OpenSSL build lacks it'
                 end
        raise CryptoUnavailableError,
              "secp256k1 ECDH is unavailable in #{::OpenSSL::OPENSSL_LIBRARY_VERSION} (#{reason}); " \
              'NIP-04 and NIP-44 encryption both need it'
      end

      # ECDH on validated, in-range inputs. The peer is the even-Y point with
      # X coordinate `x_bytes` (BIP-340 lift_x), encoded as "02" || x.
      def derive(d_bytes, x_bytes)
        theirs = begin
          ::OpenSSL::PKey.read(public_key_der(x_bytes))
        rescue ::OpenSSL::OpenSSLError
          raise EncryptionError, 'x is not on the curve'
        end

        begin
          secret = ::OpenSSL::PKey.read(private_key_der(d_bytes)).derive(theirs)
        rescue ::OpenSSL::OpenSSLError => e
          raise EncryptionError, "ECDH failed: #{e.message}"
        end
        raise EncryptionError, "ECDH returned #{secret.bytesize} bytes, expected 32" unless secret.bytesize == 32

        secret
      end

      # SubjectPublicKeyInfo (RFC 5480) for the compressed point "02" || x.
      def public_key_der(x_bytes)
        ::OpenSSL::ASN1::Sequence.new(
          [
            ::OpenSSL::ASN1::Sequence.new(
              [::OpenSSL::ASN1::ObjectId.new(EC_PUBLIC_KEY_OID), ::OpenSSL::ASN1::ObjectId.new(SECP256K1_OID)]
            ),
            ::OpenSSL::ASN1::BitString.new("\x02".b + x_bytes)
          ]
        ).to_der
      end

      # ECPrivateKey (RFC 5915) holding exactly 32 bytes of scalar, leading
      # zeros included. The optional publicKey field is left out; OpenSSL
      # derives it from the scalar.
      def private_key_der(d_bytes)
        ::OpenSSL::ASN1::Sequence.new(
          [
            ::OpenSSL::ASN1::Integer.new(1),
            ::OpenSSL::ASN1::OctetString.new(d_bytes),
            ::OpenSSL::ASN1::ObjectId.new(SECP256K1_OID, 0, :EXPLICIT)
          ]
        ).to_der
      end
    end
  end
end
