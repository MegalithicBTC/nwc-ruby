# frozen_string_literal: true

require 'async'
require 'async/clock'
require 'async/http/endpoint'
require 'async/websocket/client'

module NwcRuby
  module Transport
    # A reliable long-running connection to a Nostr relay.
    #
    # This is the reliability layer: everything the developer shouldn't have to
    # think about. It handles:
    #
    #   - RFC 6455 ping every `ping_interval` seconds (keeps middleboxes from
    #     idle-closing the socket; the relay's pong reply is handled by the
    #     protocol layer automatically)
    #   - forced recycle every `recycle_interval` (belt-and-suspenders against
    #     relay bugs or silent connection death)
    #   - capped exponential backoff on reconnect (1s → 2 → 4 → ... → 60s)
    #   - SIGTERM / SIGINT handling for clean Kamal deploys
    #
    # Usage:
    #
    #   conn = RelayConnection.new(url: "wss://relay.rizful.com")
    #   conn.on_event { |event_hash| ... }
    #   conn.on_open  { |c| c.send_req(sub_id: "foo", filters: [...]) }
    #   conn.run!  # blocks until stop! or signal
    class RelayConnection
      DEFAULT_PING_INTERVAL    = 15
      DEFAULT_RECYCLE_INTERVAL = 300
      DEFAULT_MAX_BACKOFF      = 60

      attr_reader :url, :logger

      def initialize(url:,
                     ping_interval: DEFAULT_PING_INTERVAL,
                     recycle_interval: DEFAULT_RECYCLE_INTERVAL,
                     max_backoff: DEFAULT_MAX_BACKOFF,
                     poll_interval: nil,
                     logger: default_logger,
                     install_signal_traps: true)
        @url              = url
        @ping_interval    = ping_interval
        @recycle_interval = recycle_interval
        @max_backoff      = max_backoff
        @poll_interval    = poll_interval
        @logger           = logger

        @event_cb         = nil
        @open_cb          = nil
        @error_cb         = nil
        @poll_cb          = nil
        @stop             = false
        @signal_traps     = install_signal_traps
        @top_task         = nil
      end

      def on_event(&block) = @event_cb = block
      def on_open(&block) = @open_cb = block
      def on_error(&block) = @error_cb = block
      def on_poll(&block) = @poll_cb = block

      def stop!
        @stop = true
        # Close the websocket to unblock the read loop. The @stop flag
        # will cause the run loop to exit on its own. We avoid calling
        # @top_task.stop here because stop! may be called from a
        # different thread than the Async reactor.
        begin
          @conn&.close
        rescue StandardError
          nil
        end
      end

      # Blocks forever, reconnecting as needed, until #stop! is called
      # or SIGTERM / SIGINT is received.
      def run!
        install_traps if @signal_traps
        backoff = 1

        Async do |top|
          @top_task = top
          until @stop
            begin
              run_one_connection(top)
              backoff = 1
            rescue StandardError => e
              break if @stop

              @logger.warn("[nwc] connection failed: #{e.class}: #{e.message}")
              @error_cb&.call(e)
              sleep_seconds = [backoff, @max_backoff].min
              @logger.info("[nwc] reconnecting in #{sleep_seconds}s")
              sleep sleep_seconds
              backoff *= 2
            end
          end
        ensure
          @top_task = nil
        end
      end

      # Send raw client->relay message (e.g. REQ, EVENT, CLOSE). Safe to call
      # from within on_open / on_event callbacks.
      def send_message(message)
        raise TransportError, 'not connected' unless @conn

        @conn.write(Protocol::WebSocket::TextMessage.generate(message))
        @conn.flush
      end

      # Helper: send ["REQ", sub_id, filter1, filter2, ...]
      def send_req(sub_id:, filters:)
        send_message(['REQ', sub_id, *Array(filters)])
      end

      # Helper: send ["EVENT", event_hash]
      def send_event(event_hash)
        send_message(['EVENT', event_hash])
      end

      # Helper: send ["CLOSE", sub_id]
      def send_close(sub_id)
        send_message(['CLOSE', sub_id])
      end

      private

      def run_one_connection(top)
        endpoint  = Async::HTTP::Endpoint.parse(@url, alpn_protocols: ['http/1.1'])
        opened_at = Async::Clock.now
        @logger.info("[nwc] connecting to #{@url}")

        Async::WebSocket::Client.connect(endpoint) do |conn|
          @conn = conn

          heartbeat = top.async do
            loop do
              conn.send_ping
              conn.flush
              @logger.debug("[nwc] ping sent")

              sleep @ping_interval
              break if @stop

              if Async::Clock.now - opened_at > @recycle_interval
                raise TransportError, "recycle (#{@recycle_interval}s)"
              end
            end
          end

          # Some relays (e.g. strfry) store ephemeral events temporarily but
          # do not push them to active subscriptions. Periodic re-subscribe
          # forces the relay to return any newly-stored events.
          poll = if @poll_interval && @poll_cb
                   top.async do
                     loop do
                       sleep @poll_interval
                       break if @stop

                       begin
                         @poll_cb.call(self)
                       rescue StandardError => e
                         @logger.warn("[nwc] poll error: #{e.message}")
                       end
                     end
                   end
                 end

          @open_cb&.call(self)
          read_loop(conn)
        ensure
          heartbeat&.stop
          poll&.stop
          @conn = nil
          begin
            conn&.close
          rescue StandardError
            nil
          end
        end
      end

      def read_loop(conn)
        while (message = conn.read)
          break if @stop

          begin
            parsed = JSON.parse(message.buffer)
          rescue JSON::ParserError => e
            @logger.warn("[nwc] malformed JSON from relay: #{e.message}")
            next
          end

          dispatch(parsed)
        end
      end

      # Relay -> client messages: ["EVENT", sub_id, event], ["EOSE", sub_id],
      # ["OK", event_id, accepted_bool, message], ["NOTICE", message], ["CLOSED", sub_id, reason].
      def dispatch(message)
        case message[0]
        when 'EVENT'
          @event_cb&.call(message[1], message[2])
        when 'OK'
          @logger.debug("[nwc] OK #{message[1]} accepted=#{message[2]} msg=#{message[3]}")
        when 'EOSE'
          @logger.debug("[nwc] EOSE #{message[1]}")
        when 'NOTICE'
          @logger.info("[nwc] NOTICE #{message[1]}")
        when 'CLOSED'
          @logger.info("[nwc] CLOSED #{message[1]} #{message[2]}")
        else
          @logger.debug("[nwc] unknown message type: #{message[0]}")
        end
      end

      def install_traps
        %w[TERM INT].each do |sig|
          trap(sig) do
            @stop = true
            # Close the socket to unblock the read loop.
            begin
              @conn&.close
            rescue StandardError # rubocop:disable Lint/SuppressedException
            end
          end
        end
      end

      def default_logger
        logger = Logger.new($stdout)
        logger.level = ENV['NWC_LOG_LEVEL'] ? Logger.const_get(ENV['NWC_LOG_LEVEL'].upcase) : Logger::INFO
        logger
      end
    end
  end
end
