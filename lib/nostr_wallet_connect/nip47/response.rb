# frozen_string_literal: true

module NostrWalletConnect
  module NIP47
    # Parses an incoming kind 23195 response event.
    class Response
      attr_reader :result_type, :result, :error, :request_id, :event

      def initialize(result_type:, result:, error:, request_id:, event:)
        @result_type = result_type
        @result      = result
        @error       = error
        @request_id  = request_id
        @event       = event
      end

      def success?
        @error.nil? && !@result.nil?
      end

      def error_code
        @error && @error['code']
      end

      def error_message
        @error && @error['message']
      end

      # @param event [Event] the kind 23195 event (already signature-verified)
      # @param client_privkey [String] hex
      # @param wallet_pubkey [String] hex
      # @return [Response]
      def self.parse(event, client_privkey, wallet_pubkey)
        # Tags: ["p", client_pubkey], ["e", request_event_id]
        e_tag = event.tags.find { |t| t[0] == 'e' }
        request_id = e_tag && e_tag[1]

        plaintext = decrypt(event.content, client_privkey, wallet_pubkey)
        data = JSON.parse(plaintext)

        new(
          result_type: data['result_type'],
          result: data['result'],
          error: data['error'],
          request_id: request_id,
          event: event
        )
      end

      # Try NIP-44 v2 first; fall back to NIP-04 if the version byte is wrong.
      def self.decrypt(content, client_privkey, wallet_pubkey)
        NIP44::Cipher.decrypt(content, client_privkey, wallet_pubkey)
      rescue EncryptionError
        NIP04::Cipher.decrypt(content, client_privkey, wallet_pubkey)
      end
    end
  end
end
