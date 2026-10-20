# frozen_string_literal: true

module NwcRuby
  module NIP04
    # NIP-04: legacy DM encryption. AES-256-CBC, PKCS7 padding, random 16-byte IV.
    # Key is the raw ECDH X coordinate (no hashing).
    # Payload format: "<base64_ciphertext>?iv=<base64_iv>"
    #
    # Deprecated in general, but still required for NWC because many wallet
    # services have not migrated: they emit NIP-04 requests/responses (kind
    # 23194/23195) and NIP-04 notifications (kind 23196) alongside or instead
    # of NIP-44 v2.
    module Cipher
      module_function

      def encrypt(plaintext, privkey_hex, pubkey_hex)
        encrypt_with(plaintext, Crypto::Conversation.new(privkey_hex, pubkey_hex))
      end

      # `encrypt`, reusing the conversation's cached key instead of redoing ECDH.
      #
      # @param conversation [Crypto::Conversation]
      def encrypt_with(plaintext, conversation)
        iv = SecureRandom.bytes(16)

        cipher = OpenSSL::Cipher.new('aes-256-cbc').encrypt
        cipher.key = conversation.nip04_key
        cipher.iv  = iv
        ct = cipher.update(plaintext.encode('UTF-8')) + cipher.final

        "#{Base64.strict_encode64(ct)}?iv=#{Base64.strict_encode64(iv)}"
      end

      def decrypt(payload, privkey_hex, pubkey_hex)
        decrypt_with(payload, Crypto::Conversation.new(privkey_hex, pubkey_hex))
      end

      # `decrypt`, reusing the conversation's cached key instead of redoing
      # ECDH. The payload is checked before the key is touched.
      #
      # @param conversation [Crypto::Conversation]
      def decrypt_with(payload, conversation)
        raise EncryptionError, 'malformed NIP-04 payload' unless payload.include?('?iv=')

        ct_b64, iv_b64 = payload.split('?iv=', 2)
        ct = Base64.strict_decode64(ct_b64)
        iv = Base64.strict_decode64(iv_b64)
        raise EncryptionError, 'invalid IV length' unless iv.bytesize == 16

        cipher = OpenSSL::Cipher.new('aes-256-cbc').decrypt
        cipher.key = conversation.nip04_key
        cipher.iv  = iv
        (cipher.update(ct) + cipher.final).force_encoding('UTF-8')
      rescue OpenSSL::Cipher::CipherError, ArgumentError => e
        raise EncryptionError, "NIP-04 decryption failed: #{e.message}"
      end
    end
  end
end
