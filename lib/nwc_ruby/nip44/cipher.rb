# frozen_string_literal: true

module NwcRuby
  module NIP44
    # NIP-44 v2 encryption. The current Nostr DM encryption, and the one NWC
    # wallet services advertise via `["encryption", "nip44_v2"]` on kind 13194.
    #
    # Algorithm (verbatim from the spec):
    #   1. shared_x = X coordinate of ECDH(priv, pub)  -- 32 bytes, no hashing
    #   2. conversation_key = HKDF-extract(IKM=shared_x, salt="nip44-v2")
    #   3. keys = HKDF-expand(PRK=conversation_key, info=nonce32, L=76)
    #      split into chacha_key[0..32] || chacha_nonce[32..44] || hmac_key[44..76]
    #   4. Plaintext is prefixed with u16-BE length, then zero-padded to a
    #      power-of-two chosen by a specific ladder (min 32 bytes, max 65536).
    #   5. Encrypt with plain ChaCha20 (NOT ChaCha20-Poly1305).
    #   6. mac = HMAC-SHA256(hmac_key, ciphertext, aad=nonce)
    #   7. payload = base64( 0x02 || nonce32 || ciphertext || mac32 )
    #
    # Security-critical invariants:
    #   - MAC is verified in constant time BEFORE decryption returns plaintext.
    #   - Unknown version bytes are rejected.
    #   - Padding is validated on decrypt (length prefix sanity + trailing zeros).
    #
    # Reference vectors: https://github.com/paulmillr/nip44/blob/main/nip44.vectors.json
    module Cipher
      module_function

      VERSION          = 2
      MIN_PLAINTEXT    = 1
      MAX_PLAINTEXT    = 65_535
      MIN_PADDED_LEN   = 32
      SALT             = 'nip44-v2'

      # @param plaintext [String] UTF-8 plaintext (1..65535 bytes)
      # @param privkey_hex [String] our private key, 32-byte hex
      # @param pubkey_hex [String] their x-only pubkey, 32-byte hex
      # @param nonce [String, nil] optional 32-byte nonce (for tests); random if nil
      # @return [String] base64 payload
      def encrypt(plaintext, privkey_hex, pubkey_hex, nonce: nil)
        pt_bytes = plaintext.to_s.dup.force_encoding('UTF-8').b
        if pt_bytes.bytesize < MIN_PLAINTEXT || pt_bytes.bytesize > MAX_PLAINTEXT
          raise EncryptionError, 'plaintext length must be 1..65535 bytes'
        end

        conversation_key = derive_conversation_key(privkey_hex, pubkey_hex)
        nonce ||= SecureRandom.bytes(32)
        raise EncryptionError, 'nonce must be 32 bytes' unless nonce.bytesize == 32

        chacha_key, chacha_nonce, hmac_key = derive_message_keys(conversation_key, nonce)
        padded     = pad(pt_bytes)
        ciphertext = chacha20(chacha_key, chacha_nonce, padded)
        mac        = OpenSSL::HMAC.digest('SHA256', hmac_key, nonce + ciphertext)

        Base64.strict_encode64([VERSION].pack('C') + nonce + ciphertext + mac)
      end

      # @param payload [String] base64 NIP-44 payload
      # @return [String] UTF-8 plaintext
      # rubocop:disable Metrics/AbcSize
      def decrypt(payload, privkey_hex, pubkey_hex)
        raise EncryptionError, 'payload is nil or empty' if payload.nil? || payload.empty?
        raise EncryptionError, "payload starts with '#' (not encrypted)" if payload.start_with?('#')

        raw = begin
          Base64.strict_decode64(payload)
        rescue ArgumentError
          raise EncryptionError, 'payload is not valid base64'
        end

        if raw.bytesize < 1 + 32 + MIN_PADDED_LEN + 32 || raw.bytesize > 1 + 32 + 65_536 + 32
          raise EncryptionError, 'payload length out of range'
        end

        version = raw.byteslice(0, 1).unpack1('C')
        raise EncryptionError, "unsupported NIP-44 version: #{version}" unless version == VERSION

        nonce      = raw.byteslice(1, 32)
        mac        = raw.byteslice(raw.bytesize - 32, 32)
        ciphertext = raw.byteslice(33, raw.bytesize - 33 - 32)

        conversation_key = derive_conversation_key(privkey_hex, pubkey_hex)
        chacha_key, chacha_nonce, hmac_key = derive_message_keys(conversation_key, nonce)

        expected_mac = OpenSSL::HMAC.digest('SHA256', hmac_key, nonce + ciphertext)
        raise EncryptionError, 'NIP-44 MAC verification failed' unless secure_compare(mac, expected_mac)

        padded = chacha20(chacha_key, chacha_nonce, ciphertext)
        unpad(padded).force_encoding('UTF-8')
      end
      # rubocop:enable Metrics/AbcSize

      # --- Internals ------------------------------------------------------

      def derive_conversation_key(privkey_hex, pubkey_hex)
        shared = Crypto::ECDH.shared_x(privkey_hex, pubkey_hex)
        hkdf_extract(SALT.b, shared)
      end

      def derive_message_keys(conversation_key, nonce)
        keys = hkdf_expand(conversation_key, nonce, 76)
        [keys.byteslice(0, 32), keys.byteslice(32, 12), keys.byteslice(44, 32)]
      end

      # HKDF-extract(salt, IKM) = HMAC-SHA256(salt, IKM). Returns 32 bytes.
      def hkdf_extract(salt, ikm)
        OpenSSL::HMAC.digest('SHA256', salt, ikm)
      end

      # HKDF-expand(PRK, info, L). RFC 5869.
      def hkdf_expand(prk, info, length)
        out = String.new(encoding: Encoding::BINARY)
        t   = String.new(encoding: Encoding::BINARY)
        counter = 1
        while out.bytesize < length
          t = OpenSSL::HMAC.digest('SHA256', prk, t + info + [counter].pack('C'))
          out << t
          counter += 1
        end
        out.byteslice(0, length)
      end

      # Plain ChaCha20, 20 rounds, 96-bit nonce, 256-bit key.
      def chacha20(key, nonce, data)
        cipher = OpenSSL::Cipher.new('chacha20')
        cipher.encrypt
        # OpenSSL's "chacha20" wants a 16-byte IV: 4-byte counter (little-endian, 0) + 12-byte nonce.
        cipher.key = key
        cipher.iv  = [0].pack('V') + nonce
        cipher.update(data) + cipher.final
      end

      # Pad plaintext: prepend u16-BE length, then zero-pad to `calc_padded_len(n)`.
      def pad(pt_bytes)
        n = pt_bytes.bytesize
        padded_len = calc_padded_len(n)
        prefix     = [n].pack('n') # u16 big-endian
        zeros      = "\x00".b * (padded_len - n)
        prefix + pt_bytes + zeros
      end

      # Spec's ladder: minimum 32, then power-of-two chunks.
      def calc_padded_len(unpadded_len)
        return MIN_PADDED_LEN if unpadded_len <= MIN_PADDED_LEN

        # next_power = 1 << (ceil(log2(unpadded_len - 1)))
        next_power = 1 << (unpadded_len - 1).bit_length
        chunk = next_power <= 256 ? 32 : next_power / 8
        (((unpadded_len - 1) / chunk) + 1) * chunk
      end

      def unpad(padded)
        raise EncryptionError, 'padded data too short' if padded.bytesize < 2 + MIN_PADDED_LEN - 2

        n = padded.byteslice(0, 2).unpack1('n')
        raise EncryptionError, 'invalid padding length' if n < MIN_PLAINTEXT || n > MAX_PLAINTEXT

        pt = padded.byteslice(2, n)
        raise EncryptionError, 'truncated padded plaintext' if pt.nil? || pt.bytesize != n

        expected_total = 2 + calc_padded_len(n)
        raise EncryptionError, 'padded length mismatch' unless padded.bytesize == expected_total

        pt
      end

      # Constant-time byte comparison.
      def secure_compare(a, b)
        return false unless a.bytesize == b.bytesize

        acc = 0
        a.bytes.zip(b.bytes) { |x, y| acc |= x ^ y }
        acc.zero?
      end
    end
  end
end
