# frozen_string_literal: true

module NostrWalletConnect
  module NIP47
    # Parses the kind 13194 "info" event — the wallet service's capability
    # advertisement. The `content` is a plaintext space-separated list of
    # supported methods. Tags optionally include:
    #   ["encryption",    "nip44_v2 nip04"]   -- supported encryption schemes
    #   ["notifications", "payment_received payment_sent"]
    class Info
      attr_reader :methods, :encryption_schemes, :notification_types, :event

      def initialize(methods:, encryption_schemes:, notification_types:, event:)
        @methods            = methods
        @encryption_schemes = encryption_schemes
        @notification_types = notification_types
        @event              = event
      end

      def self.parse(event)
        methods = event.content.to_s.strip.split(/\s+/).reject(&:empty?)

        enc_tag = event.tags.find { |t| t[0] == "encryption" }
        schemes = if enc_tag
                    enc_tag[1].to_s.strip.split(/\s+/)
                  else
                    # Spec: absence means nip04 only.
                    ["nip04"]
                  end

        notif_tag = event.tags.find { |t| t[0] == "notifications" }
        notif_types = notif_tag ? notif_tag[1].to_s.strip.split(/\s+/) : []

        new(methods: methods, encryption_schemes: schemes, notification_types: notif_types, event: event)
      end

      def supports?(method)
        @methods.include?(method)
      end

      def supports_nip44?
        @encryption_schemes.include?("nip44_v2")
      end

      def supports_nip04?
        @encryption_schemes.include?("nip04")
      end

      def preferred_encryption
        supports_nip44? ? :nip44_v2 : :nip04
      end

      # True when the connection exposes no fund-moving methods.
      def read_only?
        (@methods & Methods::MUTATING).empty?
      end

      def read_write?
        !read_only?
      end

      def supports_notifications?
        !@notification_types.empty?
      end
    end
  end
end
