# frozen_string_literal: true

require 'async'
require 'async/clock'
require 'async/http/endpoint'
require 'async/websocket/client'

module NwcRuby
  # The main public API.
  #
  #   client = NwcRuby::Client.from_uri(ENV["NWC_URL"])
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
    DEFAULT_TIMEOUT         = 30
    DEFAULT_CONNECT_RETRIES = 2
    # Pause before each retry round; the last value repeats.
    CONNECT_BACKOFF = [0.25, 1.0].freeze

    attr_reader :connection_string, :logger

    def self.from_uri(uri_string, **)
      new(ConnectionString.parse(uri_string), **)
    end

    # @param request_timeout [Numeric] overall budget per public call, covering
    #   the info fetch, connecting, and waiting for the wallet's response.
    # @param connect_retries [Integer] extra rounds through the relay list when
    #   a request fails before it is sent. Never applies after sending.
    def initialize(connection_string, logger: nil, request_timeout: DEFAULT_TIMEOUT,
                   connect_retries: DEFAULT_CONNECT_RETRIES)
      @connection_string = connection_string
      @logger            = logger || default_logger
      @request_timeout   = request_timeout
      @connect_retries   = connect_retries
      @info              = nil
    end

    # -- Introspection --------------------------------------------------------

    # Fetch and cache the kind 13194 info event. This tells us which methods
    # the wallet service supports and which encryption schemes it accepts.
    # Raises NotSentError (never anything lower-level) if it can't be fetched.
    def info(refresh: false)
      return @info if @info && !refresh

      @info = fetch_info(new_deadline)
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

    # Stop a running subscribe_to_notifications listener.
    def stop_notifications!
      @notification_connection&.stop!
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
    def subscribe_to_notifications(since: Time.now.to_i, # rubocop:disable Metrics/MethodLength
                                   kinds: [NIP47::Methods::KIND_NOTIFICATION_NIP04,
                                           NIP47::Methods::KIND_NOTIFICATION_NIP44],
                                   sub_id: "nwc-#{SecureRandom.hex(4)}",
                                   poll_interval: nil,
                                   &block)
      raise ArgumentError, 'block required' unless block

      seen = {}
      last_seen_at = since
      filters = [{
        'authors' => [@connection_string.wallet_pubkey],
        '#p' => [@connection_string.client_pubkey],
        'kinds' => kinds,
        'since' => since
      }]

      conn = Transport::RelayConnection.new(
        url: @connection_string.relays.first,
        logger: @logger,
        poll_interval: poll_interval
      )
      @notification_connection = conn

      conn.on_open do |c|
        @logger.info(
          "[nwc] subscribing sub_id=#{sub_id} client_pubkey=#{@connection_string.client_pubkey} " \
          "wallet_pubkey=#{@connection_string.wallet_pubkey} kinds=#{kinds.inspect} since=#{since}"
        )
        c.send_req(sub_id: sub_id, filters: filters)
      end

      # Periodic re-subscribe: some relays (e.g. strfry) store ephemeral
      # events temporarily but never push them to existing subscriptions.
      # Re-sending the REQ with the same sub_id forces the relay to return
      # any newly-stored events.
      conn.on_poll do |c|
        filters[0]['since'] = last_seen_at
        @logger.debug("[nwc] re-subscribing sub_id=#{sub_id} since=#{last_seen_at}")
        c.send_req(sub_id: sub_id, filters: filters)
      end

      conn.on_event do |_sub, event_hash|
        event = Event.from_hash(event_hash)
        next unless authentic?(event)
        # Notification.parse raises on any other kind, which would tear down
        # the listener; the relay chooses what it sends us, not the filter.
        next unless kinds.include?(event.kind)

        # Advance the poll watermark so we don't re-fetch old events.
        last_seen_at = event.created_at if event.created_at && event.created_at > last_seen_at

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

    # Every event arriving from a relay must clear this before it is parsed.
    # `valid_signature?` recomputes the id, so a passing event is byte-for-byte
    # what the wallet signed — which is what makes the kind and tag checks
    # below meaningful.
    def authentic?(event)
      event.valid_signature? && event.pubkey == @connection_string.wallet_pubkey
    end

    # A relay is not trusted to honour the REQ filter it was sent, so the
    # response is bound to the request here. Without this an older but genuine
    # response (say, a past "payment succeeded") can be replayed against a new
    # request.
    def response_to?(event, request_id)
      e_tag = event.tags.find { |t| t[0] == 'e' }
      !e_tag.nil? && e_tag[1] == request_id
    end

    # Advisory only — the relay decides what it actually sends, so `fetch_info`
    # re-checks the author and kind on whatever comes back.
    def info_filter
      {
        'authors' => [@connection_string.wallet_pubkey],
        'kinds' => [NIP47::Methods::KIND_INFO],
        'limit' => 1
      }
    end

    def response_filter(request_id)
      {
        'authors' => [@connection_string.wallet_pubkey],
        'kinds' => [NIP47::Methods::KIND_RESPONSE],
        '#e' => [request_id],
        '#p' => [@connection_string.client_pubkey]
      }
    end

    # Every request has two phases. Phase 1 (info fetch, DNS, connect, TLS,
    # upgrade, REQ write) cannot have reached the wallet, so its failures raise
    # NotSentError and are retried. Phase 2 starts at the EVENT write: the
    # wallet may have acted, so failures there are ambiguous and never retried.
    def call(method, params)
      deadline = new_deadline
      ensure_supports!(method, deadline)

      # Built once so every relay and retry carries the same event id.
      request_event = NIP47::Request.build(
        method: method,
        params: params,
        client_privkey: @connection_string.secret,
        wallet_pubkey: @connection_string.wallet_pubkey,
        encryption: @info.preferred_encryption
      )

      response = with_relays(deadline) { |url| send_request(url, deadline, method, request_event) }
      unless response.success?
        raise WalletServiceError.new(response.error_code || 'UNKNOWN', response.error_message || '')
      end

      response.result
    end

    def send_request(url, deadline, method, request_event)
      sent = false
      response, failure = websocket_session(url, deadline) do |conn|
        sub_id = "rsp-#{SecureRandom.hex(4)}"
        write_frame(conn, ['REQ', sub_id, response_filter(request_event.id)])
        # Set before the write: a write that fails part-way may still deliver.
        sent = true
        write_frame(conn, ['EVENT', request_event.to_h])
        read_response(conn, sub_id, request_event.id)
      end
      return response if response

      raise_not_sent(url, failure) unless sent
      raise failure if failure.is_a?(Error)
      if failure.is_a?(Async::TimeoutError)
        raise TimeoutError, "no response to #{method} within #{@request_timeout}s", cause: failure
      end

      raise TransportError,
            "connection to relay #{relay_host(url)} failed after #{method} was sent " \
            "(#{failure.class}: #{failure.message})",
            cause: failure
    end

    def read_response(conn, sub_id, request_id)
      while (msg = conn.read)
        parsed = parse_frame(msg)
        # Still ambiguous: the relay is untrusted and may have forwarded it anyway.
        if parsed && parsed[0] == 'OK' && parsed[1] == request_id && parsed[2] == false
          raise TransportError, "relay rejected the request: #{parsed[3].to_s[0, 200]}"
        end

        event = relay_event(parsed, sub_id)
        next unless event && event.kind == NIP47::Methods::KIND_RESPONSE && response_to?(event, request_id)

        return NIP47::Response.parse(event, @connection_string.secret, @connection_string.wallet_pubkey)
      end
      raise TransportError, 'relay closed the connection before the wallet responded'
    end

    # Entirely phase 1: nothing has been sent to the wallet yet.
    def fetch_info(deadline)
      with_relays(deadline) { |url| fetch_info_from(url, deadline) }
    end

    def fetch_info_from(url, deadline)
      info, failure = websocket_session(url, deadline) do |conn|
        sub_id = "info-#{SecureRandom.hex(4)}"
        write_frame(conn, ['REQ', sub_id, info_filter])
        read_info(conn, sub_id)
      end
      return info if info

      raise_not_sent(url, failure) if failure
      raise InfoUnavailableError,
            "wallet service published no info event (kind 13194) on relay #{relay_host(url)}"
    end

    def read_info(conn, sub_id)
      while (msg = conn.read)
        parsed = parse_frame(msg)
        return nil if parsed && parsed[0] == 'EOSE' && parsed[1] == sub_id

        # A rejected event must not end the read: a genuine info event may
        # still follow, and the deadline bounds the wait.
        event = relay_event(parsed, sub_id)
        return NIP47::Info.parse(event) if event&.kind == NIP47::Methods::KIND_INFO
      end
      nil
    end

    def ensure_supports!(method, deadline)
      @info ||= fetch_info(deadline)
      return if @info.supports?(method)

      raise UnsupportedMethodError,
            "wallet service does not advertise `#{method}`. Supported: #{@info.methods.join(', ')}"
    end

    # Tries each relay in turn, then up to @connect_retries more rounds with
    # backoff, all inside `deadline`. Only NotSentError is retried.
    def with_relays(deadline)
      last_failure = nil
      (@connect_retries + 1).times do |round|
        if round.positive?
          pause = CONNECT_BACKOFF[round - 1] || CONNECT_BACKOFF.last
          break if Async::Clock.now + pause >= deadline

          sleep pause
        end

        @connection_string.relays.each do |url|
          break if Async::Clock.now >= deadline

          return yield(url)
        rescue NotSentError => e
          last_failure = e
          @logger.warn("[nwc] #{e.message}")
        end
      end
      raise last_failure if last_failure

      raise NotSentError, "not sent: #{@request_timeout}s deadline passed before a relay could be tried"
    end

    # One websocket session bounded by `deadline`. Exceptions are rescued
    # inside the task and returned so Async never logs them as unhandled.
    # @return [Array(Object, Exception)] the block's value and any failure
    def websocket_session(url, deadline)
      value   = nil
      failure = nil
      Sync do |task|
        task.with_timeout(remaining(deadline)) do
          endpoint = Async::HTTP::Endpoint.parse(url, alpn_protocols: ['http/1.1'])
          Async::WebSocket::Client.connect(endpoint) { |conn| value = yield(conn) }
        end
      rescue StandardError => e
        failure = e
      end
      [value, failure]
    end

    def raise_not_sent(url, failure)
      raise failure if failure.is_a?(NotSentError)

      reason = failure.is_a?(Async::TimeoutError) ? 'timed out' : "#{failure.class}: #{failure.message}"
      raise NotSentError, "not sent: relay #{relay_host(url)} failed before the request was written (#{reason})",
            cause: failure
    end

    # An authentic wallet event delivered on `sub_id`, or nil.
    def relay_event(parsed, sub_id)
      return unless parsed && parsed[0] == 'EVENT' && parsed[1] == sub_id && parsed[2].is_a?(Hash)

      event = Event.from_hash(parsed[2])
      event if authentic?(event)
    end

    def parse_frame(msg)
      parsed = JSON.parse(msg.buffer)
      parsed if parsed.is_a?(Array)
    rescue JSON::ParserError
      nil
    end

    def write_frame(conn, message)
      conn.write(Protocol::WebSocket::TextMessage.generate(message))
      conn.flush
    end

    # Host only: relay URLs can carry auth tokens in the path or query.
    def relay_host(url)
      URI.parse(url).host || 'unknown'
    rescue URI::InvalidURIError
      'unparseable relay URL'
    end

    def new_deadline
      Async::Clock.now + @request_timeout
    end

    def remaining(deadline)
      [deadline - Async::Clock.now, 0].max
    end

    def default_logger
      logger = Logger.new($stdout)
      logger.level = ENV['NWC_LOG_LEVEL'] ? Logger.const_get(ENV['NWC_LOG_LEVEL'].upcase) : Logger::INFO
      logger
    end
  end
end
