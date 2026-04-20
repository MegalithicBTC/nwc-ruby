# frozen_string_literal: true

module NostrWalletConnect
  module NIP47
    # Builds a signed kind 23194 request event with the JSON-RPC payload
    # encrypted using either NIP-44 v2 or NIP-04.
    module Request
      module_function

      # @param method [String] NIP-47 method name
      # @param params [Hash] method-specific params
      # @param client_privkey [String] hex
      # @param wallet_pubkey [String] hex
      # @param encryption [Symbol] :nip44_v2 or :nip04
      # @param expiration [Integer, nil] optional unix timestamp
      # @return [Event]
      def build(method:, params:, client_privkey:, wallet_pubkey:, encryption: :nip44_v2, expiration: nil)
        payload = JSON.generate({ 'method' => method, 'params' => params })
        ciphertext = case encryption
                     when :nip44_v2 then NIP44::Cipher.encrypt(payload, client_privkey, wallet_pubkey)
                     when :nip04    then NIP04::Cipher.encrypt(payload, client_privkey, wallet_pubkey)
                     else raise ArgumentError, "unknown encryption: #{encryption}"
                     end

        tags = [['p', wallet_pubkey]]
        tags << %w[encryption nip44_v2] if encryption == :nip44_v2
        tags << ['expiration', expiration.to_s] if expiration

        client_pubkey = Crypto::Keys.public_key_from_private(client_privkey)
        event = Event.new(pubkey: client_pubkey, kind: Methods::KIND_REQUEST, content: ciphertext, tags: tags)
        event.sign!(client_privkey)
      end
    end
  end
end
