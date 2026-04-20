# frozen_string_literal: true

require 'async'
require 'async/http/endpoint'
require 'async/websocket/client'

module NostrWalletConnect
  # The main public API.
  #
  #   client = NostrWalletConnect::Client.from_uri(ENV["NWC_URL"])
  #
  #   # One-shot request/response (transparently opens a WS, sends, waits, closes):
  #   info    = client.get_info
  #   balance = client.get_balance
  #   invoice = client.make_invoice(amount: 1_000, description: "tip")
  #
  #   # Long-running listener (transparently heartbeats, reconnects, resumes):
  #   client.subscribe_to_notifications do |notification|
  #     puts "Got #{notification.amount_msats} msats"
  #   end
  class Client
    DEFAULT_TIMEOUT = 30

    attr_reader :connection_string, :logger

    def self.from_uri(uri_string, **)
      new(ConnectionString.parse(uri_string), **)
    end

    def initialize(connection_string, logger: nil, request_timeout: DEFAULT_TIMEOUT)
      @connection_string = connection_string
      @logger            = logger || default_logger
      @request_timeout   = request_timeout
      @info              = nil
    end

    # -- Introspection --------------------------------------------------------

    # Fetch and cache the kind 13194 info event. This tells us which methods
    # the wallet service supports and which encryption schemes it accepts.
    def info(refresh: false)
      return @info if @info && !refresh

      @info = fetch_info
    end

    def capabilities
      info.methods
    end

    def read_only?
      info.read_only?
    end

    def read_write?
      info.read_write?
    end

    # -- NIP-47 methods -------------------------------------------------------

    def pay_invoice(invoice:, amount: nil)
      params = { 'invoice' => invoice }
      params['amount'] = amount if amount
      call(NIP47::Methods::PAY_INVOICE, params)
    end

    def multi_pay_invoice(invoices:)
      call(NIP47::Methods::MULTI_PAY_INVOICE, { 'invoices' => invoices })
    end

    def pay_keysend(amount:, pubkey:, preimage: nil, tlv_records: nil)
      params = { 'amount' => amount, 'pubkey' => pubkey }
      params['preimage']    = preimage    if preimage
      params['tlv_records'] = tlv_records if tlv_records
      call(NIP47::Methods::PAY_KEYSEND, params)
    end

    def multi_pay_keysend(keysends:)
      call(NIP47::Methods::MULTI_PAY_KEYSEND, { 'keysends' => keysends })
    end

    def make_invoice(amount:, description: nil, description_hash: nil, expiry: nil, metadata: nil)
      params = { 'amount' => amount }
      params['description']      = description      if description
      params['description_hash'] = description_hash if description_hash
      params['expiry']           = expiry           if expiry
      params['metadata']         = metadata         if metadata
      call(NIP47::Methods::MAKE_INVOICE, params)
    end

    def lookup_invoice(payment_hash: nil, invoice: nil)
      raise ArgumentError, 'lookup_invoice requires payment_hash or invoice' if payment_hash.nil? && invoice.nil?

      params = {}
      params['payment_hash'] = payment_hash if payment_hash
      params['invoice']      = invoice      if invoice
      call(NIP47::Methods::LOOKUP_INVOICE, params)
    end

    def list_transactions(from: nil, until_ts: nil, limit: nil, offset: nil, unpaid: nil, type: nil)
      params = {}
      params['from']   = from       if from
      params['until']  = until_ts   if until_ts
      params['limit']  = limit      if limit
      params['offset'] = offset     if offset
      params['unpaid'] = unpaid unless unpaid.nil?
      params['type']   = type if type
      call(NIP47::Methods::LIST_TRANSACTIONS, params)
    end

    def get_balance
      call(NIP47::Methods::GET_BALANCE, {})
    end

    def get_info
      call(NIP47::Methods::GET_INFO, {})
    end

    def sign_message(message:)
      call(NIP47::Methods::SIGN_MESSAGE, { 'message' => message })
    end

    # -- Notification listener -----------------------------------------------

    # Subscribe to payment_received / payment_sent notifications from the
    # wallet service. Blocks forever, handling heartbeat and reconnect.
    #
    #   client.subscribe_to_notifications do |notification|
    #     case notification.type
    #     when "payment_received" then credit_invoice(notification.payment_hash, notification.amount_msats)
    #     when "payment_sent"     then mark_outbound_settled(notification.payment_hash)
    #     end
    #   end
    #
    # @param since [Integer] unix timestamp for the `since:` filter on the
    #   subscription; defaults to now. Pass the last-seen `created_at` on
    #   reconnect to avoid replaying history.
    # @param kinds [Array<Integer>] notification kinds to listen for. Defaults
    #   to both NIP-04 (23196) and NIP-44 v2 (23197). The listener dedupes by
    #   `payment_hash`, so receiving both is safe.
    def subscribe_to_notifications(since: Time.now.to_i,
                                   kinds: [NIP47::Methods::KIND_NOTIFICATION_NIP04,
                                           NIP47::Methods::KIND_NOTIFICATION_NIP44],
                                   sub_id: "nwc-#{SecureRandom.hex(4)}",
                                   &block)
      raise ArgumentError, 'block required' unless block

      seen = {}
      conn = Transport::RelayConnection.new(url: @connection_string.relays.first, logger: @logger)

      conn.on_open do |c|
        c.send_req(
          sub_id: sub_id,
          filters: [{
            'authors' => [@connection_string.wallet_pubkey],
            '#p' => [@connection_string.client_pubkey],
            'kinds' => kinds,
            'since' => since
          }]
        )
      end

      conn.on_event do |_sub, event_hash|
        event = Event.from_hash(event_hash)
        next unless event.valid_signature?
        next unless event.pubkey == @connection_string.wallet_pubkey

        begin
          notification = NIP47::Notification.parse(event, @connection_string.secret, @connection_string.wallet_pubkey)
        rescue EncryptionError => e
          @logger.warn("[nwc] could not decrypt notification: #{e.message}")
          next
        end

        # Dedupe: wallets that support both encryption schemes publish both
        # 23196 and 23197 for the same event.
        key = notification.payment_hash || event.id
        next if seen[key]

        seen[key] = true
        # Primitive GC to keep the hash bounded.
        seen.shift while seen.size > 10_000

        block.call(notification)
      end

      conn.run!
    end

    # -- Internals ------------------------------------------------------------

    private

    def call(method, params)
      ensure_supports!(method)
      encryption = info.preferred_encryption

      deadline = Time.now + @request_timeout
      result   = nil

      Async do
        endpoint = Async::HTTP::Endpoint.parse(@connection_string.relays.first)
        Async::WebSocket::Client.connect(endpoint) do |conn|
          request_event = NIP47::Request.build(
            method: method,
            params: params,
            client_privkey: @connection_string.secret,
            wallet_pubkey: @connection_string.wallet_pubkey,
            encryption: encryption
          )

          sub_id = "rsp-#{SecureRandom.hex(4)}"
          conn.write(Protocol::WebSocket::TextMessage.generate(['REQ', sub_id, {
                                                                 'authors' => [@connection_string.wallet_pubkey],
                                                                 'kinds' => [NIP47::Methods::KIND_RESPONSE],
                                                                 '#e' => [request_event.id],
                                                                 '#p' => [@connection_string.client_pubkey]
                                                               }]))
          conn.write(Protocol::WebSocket::TextMessage.generate(['EVENT', request_event.to_h]))
          conn.flush

          while (msg = conn.read)
            break if Time.now > deadline

            parsed = begin
              JSON.parse(msg.buffer)
            rescue JSON::ParserError
              next
            end

            next unless parsed[0] == 'EVENT' && parsed[1] == sub_id

            event = Event.from_hash(parsed[2])
            next unless event.valid_signature?
            next unless event.pubkey == @connection_string.wallet_pubkey

            result = NIP47::Response.parse(event, @connection_string.secret, @connection_string.wallet_pubkey)
            break
          end
        ensure
          begin
            conn&.close
          rescue StandardError
            nil
          end
        end
      end.wait

      raise TimeoutError, "no response to #{method} within #{@request_timeout}s" if result.nil?
      raise WalletServiceError.new(result.error_code || 'UNKNOWN', result.error_message || '') unless result.success?

      result.result
    end

    def fetch_info
      endpoint  = Async::HTTP::Endpoint.parse(@connection_string.relays.first)
      deadline  = Time.now + @request_timeout
      result    = nil

      Async do
        Async::WebSocket::Client.connect(endpoint) do |conn|
          sub_id = "info-#{SecureRandom.hex(4)}"
          conn.write(Protocol::WebSocket::TextMessage.generate(['REQ', sub_id, {
                                                                 'authors' => [@connection_string.wallet_pubkey],
                                                                 'kinds' => [NIP47::Methods::KIND_INFO],
                                                                 'limit' => 1
                                                               }]))
          conn.flush

          while (msg = conn.read)
            break if Time.now > deadline

            parsed = begin
              JSON.parse(msg.buffer)
            rescue JSON::ParserError
              next
            end

            if parsed[0] == 'EVENT' && parsed[1] == sub_id
              event  = Event.from_hash(parsed[2])
              result = NIP47::Info.parse(event) if event.valid_signature?
              break
            elsif parsed[0] == 'EOSE' && parsed[1] == sub_id
              break
            end
          end
        ensure
          begin
            conn&.close
          rescue StandardError
            nil
          end
        end
      end.wait

      if result.nil?
        raise TransportError,
              "wallet service published no info event (kind 13194) on #{@connection_string.relays.first}"
      end

      result
    end

    def ensure_supports!(method)
      return if info.supports?(method)

      raise UnsupportedMethodError,
            "wallet service does not advertise `#{method}`. Supported: #{info.methods.join(', ')}"
    end

    def default_logger
      logger = Logger.new($stdout)
      logger.level = ENV['NWC_LOG_LEVEL'] ? Logger.const_get(ENV['NWC_LOG_LEVEL'].upcase) : Logger::INFO
      logger
    end
  end
end
