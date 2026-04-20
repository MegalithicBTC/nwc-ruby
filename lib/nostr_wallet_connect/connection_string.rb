# frozen_string_literal: true

module NostrWalletConnect
  # Parses a `nostr+walletconnect://` URI.
  #
  # Canonical form:
  #   nostr+walletconnect://<wallet_service_pubkey_hex>?
  #     relay=wss://...
  #    &secret=<32_byte_hex>
  #    &lud16=<optional>
  #
  # `relay` may repeat. `secret` is the CLIENT private key (32 bytes hex); the
  # derived client pubkey is what the wallet encrypts responses to.
  class ConnectionString
    attr_reader :wallet_pubkey, :relays, :secret, :lud16

    def self.parse(uri_string)
      new(uri_string)
    end

    def initialize(uri_string)
      raise InvalidConnectionStringError, 'connection string is empty' if uri_string.nil? || uri_string.empty?

      # The built-in URI parser chokes on `nostr+walletconnect://` because of
      # the `+`, so normalize the scheme before parsing.
      normalized = uri_string.sub(%r{\Anostr\+walletconnect://}, 'https://')
      uri = URI.parse(normalized)

      unless uri_string.start_with?('nostr+walletconnect://') ||
             uri_string.start_with?('nostrwalletconnect://')
        raise InvalidConnectionStringError,
              'expected nostr+walletconnect:// scheme'
      end

      @wallet_pubkey = uri.host&.downcase
      Crypto::Keys.validate_hex32!(@wallet_pubkey, 'wallet service pubkey (host)')

      params = decode_query(uri.query || '')

      @relays = Array(params['relay'])
      raise InvalidConnectionStringError, 'at least one `relay` parameter is required' if @relays.empty?

      @secret = params['secret']&.first&.downcase
      Crypto::Keys.validate_hex32!(@secret, 'secret')

      @lud16 = params['lud16']&.first
    rescue URI::InvalidURIError => e
      raise InvalidConnectionStringError, "malformed URI: #{e.message}"
    end

    # The client's own x-only pubkey, derived from `secret`.
    def client_pubkey
      @client_pubkey ||= Crypto::Keys.public_key_from_private(@secret)
    end

    def to_s
      params = { 'relay' => @relays, 'secret' => [@secret] }
      params['lud16'] = [@lud16] if @lud16
      "nostr+walletconnect://#{@wallet_pubkey}?#{encode_query(params)}"
    end

    private

    def decode_query(query)
      result = Hash.new { |h, k| h[k] = [] }
      query.split('&').each do |pair|
        next if pair.empty?

        k, v = pair.split('=', 2)
        result[URI.decode_www_form_component(k)] << URI.decode_www_form_component(v.to_s)
      end
      result
    end

    def encode_query(params)
      params.flat_map do |k, values|
        Array(values).map { |v| "#{URI.encode_www_form_component(k)}=#{URI.encode_www_form_component(v)}" }
      end.join('&')
    end
  end
end
