# frozen_string_literal: true

require "async"
require "async/clock"
require "async/http/endpoint"
require "async/websocket/client"
require "protocol/websocket/ping_frame"

module NostrWalletConnect
  module Transport
    # A reliable long-running connection to a Nostr relay.
    #
    # This is the reliability layer: everything the developer shouldn't have to
    # think about. It handles:
    #
    #   - RFC 6455 ping every `ping_interval` seconds
    #   - pong deadline: if no pong in `pong_timeout`, reconnect
    #   - forced recycle every `recycle_interval` (belt-and-suspenders against
    #     middlebox / relay bugs that both pings survive)
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
      DEFAULT_PING_INTERVAL    = 30
      DEFAULT_PONG_TIMEOUT     = 45
      DEFAULT_RECYCLE_INTERVAL = 300
      DEFAULT_MAX_BACKOFF      = 60

      attr_reader :url, :logger

      def initialize(url:,
                     ping_interval: DEFAULT_PING_INTERVAL,
                     pong_timeout: DEFAULT_PONG_TIMEOUT,
                     recycle_interval: DEFAULT_RECYCLE_INTERVAL,
                     max_backoff: DEFAULT_MAX_BACKOFF,
                     logger: default_logger,
                     install_signal_traps: true)
        @url              = url
        @ping_interval    = ping_interval
        @pong_timeout     = pong_timeout
        @recycle_interval = recycle_interval
        @max_backoff      = max_backoff
        @logger           = logger

        @event_cb         = nil
        @open_cb          = nil
        @error_cb         = nil
        @stop             = false
        @signal_traps     = install_signal_traps
      end

      def on_event(&block); @event_cb = block; end
      def on_open(&block);  @open_cb  = block; end
      def on_error(&block); @error_cb = block; end

      def stop!
        @stop = true
      end

      # Blocks forever, reconnecting as needed, until #stop! is called
      # or SIGTERM / SIGINT is received.
      def run!
        install_traps if @signal_traps
        backoff = 1

        Async do |top|
          until @stop
            begin
              run_one_connection(top)
              backoff = 1
            rescue => e
              @logger.warn("[nwc] connection failed: #{e.class}: #{e.message}")
              @error_cb&.call(e)
              sleep_seconds = [backoff, @max_backoff].min
              @logger.info("[nwc] reconnecting in #{sleep_seconds}s")
              sleep sleep_seconds
              backoff *= 2
            end
          end
        end
      end

      # Send raw client->relay message (e.g. REQ, EVENT, CLOSE). Safe to call
      # from within on_open / on_event callbacks.
      def send_message(message)
        raise TransportError, "not connected" unless @conn

        @conn.write(Protocol::WebSocket::TextMessage.generate(message))
        @conn.flush
      end

      # Helper: send ["REQ", sub_id, filter1, filter2, ...]
      def send_req(sub_id:, filters:)
        send_message(["REQ", sub_id, *Array(filters)])
      end

      # Helper: send ["EVENT", event_hash]
      def send_event(event_hash)
        send_message(["EVENT", event_hash])
      end

      # Helper: send ["CLOSE", sub_id]
      def send_close(sub_id)
        send_message(["CLOSE", sub_id])
      end

      private

      def run_one_connection(top)
        endpoint  = Async::HTTP::Endpoint.parse(@url)
        opened_at = Async::Clock.now
        last_pong = Async::Clock.now
        @logger.info("[nwc] connecting to #{@url}")

        Async::WebSocket::Client.connect(endpoint) do |conn|
          @conn = conn
          conn.on_pong = ->(_) { last_pong = Async::Clock.now }

          heartbeat = top.async do
            loop do
              sleep @ping_interval
              break if @stop

              conn.write(Protocol::WebSocket::PingFrame.new(data: "hb"))
              conn.flush

              if Async::Clock.now - last_pong > @pong_timeout
                raise TransportError, "pong timeout (#{@pong_timeout}s)"
              end
              if Async::Clock.now - opened_at > @recycle_interval
                raise TransportError, "recycle (#{@recycle_interval}s)"
              end
            end
          end

          @open_cb&.call(self)
          read_loop(conn)
        ensure
          heartbeat&.stop
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
        when "EVENT"
          @event_cb&.call(message[1], message[2])
        when "OK"
          @logger.debug("[nwc] OK #{message[1]} accepted=#{message[2]} msg=#{message[3]}")
        when "EOSE"
          @logger.debug("[nwc] EOSE #{message[1]}")
        when "NOTICE"
          @logger.info("[nwc] NOTICE #{message[1]}")
        when "CLOSED"
          @logger.info("[nwc] CLOSED #{message[1]} #{message[2]}")
        else
          @logger.debug("[nwc] unknown message type: #{message[0]}")
        end
      end

      def install_traps
        %w[TERM INT].each do |sig|
          trap(sig) do
            @stop = true
            # Avoid logging from the trap handler (reentrancy).
          end
        end
      end

      def default_logger
        logger = Logger.new($stdout)
        logger.level = ENV["NWC_LOG_LEVEL"] ? Logger.const_get(ENV["NWC_LOG_LEVEL"].upcase) : Logger::INFO
        logger
      end
    end
  end
end
