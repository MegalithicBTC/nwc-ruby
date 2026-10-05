# frozen_string_literal: true

require 'async'
require 'async/http/endpoint'
require 'async/http/server'
require 'async/websocket/adapters/http'
require 'socket'

# A real websocket relay on 127.0.0.1 that also plays the wallet service, so
# Client is exercised over an actual socket. Runs its own reactor on a thread.
#
# behaviour on receiving the request EVENT:
#   :respond - wallet-signed success response
#   :error   - wallet-signed NIP-47 error response
#   :close   - close the websocket without responding
#   :reject  - reply ["OK", id, false, reason] and nothing else
#   :silent  - never respond
class FakeRelay
  METHODS = NwcRuby::NIP47::Methods::ALL

  attr_reader :port

  def self.free_port
    server = TCPServer.new('127.0.0.1', 0)
    server.addr[1]
  ensure
    server&.close
  end

  def initialize(wallet_priv:, client_pub:, behaviour: :respond, publish_info: true)
    @wallet_priv  = wallet_priv
    @client_pub   = client_pub
    @behaviour    = behaviour
    @publish_info = publish_info
    @frames       = []
    @lock         = Mutex.new
  end

  def url = "ws://127.0.0.1:#{@port}"

  def frames = @lock.synchronize { @frames.dup }
  def request_events = frames.select { |f| f[0] == 'EVENT' }

  def start
    @port = self.class.free_port
    @stop_r, @stop_w = IO.pipe
    @thread = Thread.new { serve }
    wait_until_listening
    self
  end

  def stop
    @stop_w.write('.')
    @thread.join(5) || @thread.kill
    [@stop_r, @stop_w].each(&:close)
  end

  private

  def serve
    Sync do
      endpoint = Async::HTTP::Endpoint.parse(url)
      server = Async::HTTP::Server.for(endpoint) do |request|
        Async::WebSocket::Adapters::HTTP.open(request) { |conn| handle(conn) } ||
          Protocol::HTTP::Response[404, {}, []]
      end
      server_task = server.run
      @stop_r.read(1)
      server_task.stop
    end
  end

  def wait_until_listening
    deadline = Time.now + 5
    begin
      TCPSocket.new('127.0.0.1', @port).close
    rescue Errno::ECONNREFUSED
      raise 'fake relay did not start' if Time.now > deadline

      sleep 0.01
      retry
    end
  end

  def handle(conn)
    response_sub = nil
    while (msg = conn.read)
      frame = JSON.parse(msg.buffer)
      @lock.synchronize { @frames << frame }

      case frame[0]
      when 'REQ'   then response_sub = on_req(conn, frame) || response_sub
      when 'EVENT' then return conn.close if on_request(conn, response_sub, frame[1]) == :close
      end
    end
  rescue Protocol::WebSocket::ClosedError, EOFError, Errno::ECONNRESET, Errno::EPIPE
    # The client hung up (e.g. its deadline expired); nothing to do.
    nil
  end

  # Answers an info REQ; returns the sub_id of any other REQ.
  def on_req(conn, frame)
    return frame[1] unless frame[2]['kinds'] == [NwcRuby::NIP47::Methods::KIND_INFO]

    push(conn, ['EVENT', frame[1], info_event.to_h]) if @publish_info
    push(conn, ['EOSE', frame[1]])
    nil
  end

  def on_request(conn, response_sub, request)
    case @behaviour
    when :respond then push(conn, ['EVENT', response_sub, response_event(request['id'], success_body).to_h])
    when :error   then push(conn, ['EVENT', response_sub, response_event(request['id'], error_body).to_h])
    when :reject  then push(conn, ['OK', request['id'], false, 'blocked: rate-limited'])
    else @behaviour
    end
  end

  def push(conn, message)
    conn.write(Protocol::WebSocket::TextMessage.generate(message))
    conn.flush
  end

  def info_event
    NwcRuby::Event.new(
      pubkey: NwcRuby::Crypto::Keys.public_key_from_private(@wallet_priv),
      kind: NwcRuby::NIP47::Methods::KIND_INFO,
      content: METHODS.join(' '),
      tags: [%w[encryption nip44_v2]]
    ).sign!(@wallet_priv)
  end

  def success_body = { 'result_type' => 'pay_invoice', 'result' => { 'preimage' => 'ab' * 32 } }

  def error_body
    { 'result_type' => 'pay_invoice', 'error' => { 'code' => 'INSUFFICIENT_BALANCE', 'message' => 'too poor' } }
  end

  def response_event(request_id, body)
    NwcRuby::Event.new(
      pubkey: NwcRuby::Crypto::Keys.public_key_from_private(@wallet_priv),
      kind: NwcRuby::NIP47::Methods::KIND_RESPONSE,
      content: NwcRuby::NIP44::Cipher.encrypt(JSON.generate(body), @wallet_priv, @client_pub),
      tags: [['p', @client_pub], ['e', request_id]]
    ).sign!(@wallet_priv)
  end
end
