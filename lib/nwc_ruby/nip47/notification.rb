# frozen_string_literal: true

module NwcRuby
  module NIP47
    # Parses kind 23196 (NIP-04) or 23197 (NIP-44 v2) notification events.
    #
    # Inner payload shape:
    #   { "notification_type": "payment_received"|"payment_sent",
    #     "notification":      { ...transaction fields... } }
    class Notification
      attr_reader :type, :data, :event

      def initialize(type:, data:, event:)
        @type  = type
        @data  = data
        @event = event
      end

      def payment_hash
        @data['payment_hash']
      end

      def amount_msats
        @data['amount']
      end

      def payment_received?
        @type == 'payment_received'
      end

      def payment_sent?
        @type == 'payment_sent'
      end

      # @param conversation [Crypto::Conversation, nil] cached keys for this
      #   client/wallet pair; derived from the two keys when nil
      def self.parse(event, client_privkey, wallet_pubkey, conversation: nil)
        conversation ||= Crypto::Conversation.new(client_privkey, wallet_pubkey)
        plaintext = case event.kind
                    when Methods::KIND_NOTIFICATION_NIP44
                      NIP44::Cipher.decrypt_with(event.content, conversation)
                    when Methods::KIND_NOTIFICATION_NIP04
                      NIP04::Cipher.decrypt_with(event.content, conversation)
                    else
                      raise ArgumentError, "not a notification kind: #{event.kind}"
                    end

        data = JSON.parse(plaintext)
        new(type: data['notification_type'], data: data['notification'] || {}, event: event)
      end
    end
  end
end
