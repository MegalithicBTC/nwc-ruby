# frozen_string_literal: true

require_relative '../support/fake_relay'

# Every request has a pre-send phase (nothing reached the wallet: safe to
# retry) and a post-send phase (the wallet may have acted). Callers can only
# avoid double payments if the gem tells them which one failed.
RSpec.describe NwcRuby::Client, 'send phases' do
  let(:wallet_priv) { NwcRuby::Crypto::Keys.generate_private_key }
  let(:wallet_pub)  { NwcRuby::Crypto::Keys.public_key_from_private(wallet_priv) }
  let(:client_priv) { NwcRuby::Crypto::Keys.generate_private_key }
  let(:client_pub)  { NwcRuby::Crypto::Keys.public_key_from_private(client_priv) }
  let(:invoice)     { 'lnbc10n1fake' }
  # Socket::ResolutionError only exists on Ruby 3.3+.
  let(:dns_error) { defined?(Socket::ResolutionError) ? Socket::ResolutionError : SocketError }

  let(:full_info) do
    NwcRuby::NIP47::Info.new(methods: NwcRuby::NIP47::Methods::ALL, encryption_schemes: ['nip44_v2'],
                             notification_types: [], event: nil)
  end

  def client_for(*relays, **opts)
    query = relays.map { |r| "relay=#{r}" }.join('&')
    described_class.from_uri(
      "nostr+walletconnect://#{wallet_pub}?#{query}&secret=#{client_priv}",
      logger: Logger.new(IO::NULL), request_timeout: 5, connect_retries: 0, **opts
    )
  end

  def with_relay(**opts)
    relay = FakeRelay.new(wallet_priv: wallet_priv, client_pub: client_pub, **opts).start
    yield relay
  ensure
    relay&.stop
  end

  def refused_url = "ws://127.0.0.1:#{FakeRelay.free_port}"

  describe 'error hierarchy' do
    it 'keeps NotSentError rescuable as TransportError' do
      expect(NwcRuby::NotSentError.new).to be_a(NwcRuby::TransportError)
      expect(NwcRuby::InfoUnavailableError.new).to be_a(NwcRuby::NotSentError)
    end

    it 'reports sent? per class' do
      expect(NwcRuby::NotSentError.new.sent?).to be false
      expect(NwcRuby::UnsupportedMethodError.new.sent?).to be false
      expect(NwcRuby::TransportError.new.sent?).to be true
      expect(NwcRuby::TimeoutError.new.sent?).to be true
      expect(NwcRuby::WalletServiceError.new('X', 'y').sent?).to be true
    end

    it 'does not make UnsupportedMethodError look retryable' do
      expect(NwcRuby::UnsupportedMethodError.new).not_to be_a(NwcRuby::TransportError)
    end
  end

  describe 'pre-send failures' do
    it 'wraps a DNS failure in fetch_info as NotSentError, naming only the host' do
      client = client_for('wss://nwc-ruby-test.invalid/v1?token=hunter2')

      expect { client.info }.to raise_error(NwcRuby::NotSentError) { |e|
        expect(e.cause).to be_a(dns_error)
        expect(e.message).to include('nwc-ruby-test.invalid')
        expect(e.message).not_to include('hunter2')
        expect(e.message).not_to include(client_priv)
        expect(e.sent?).to be false
      }
    end

    it 'never writes the EVENT when info cannot be fetched' do
      expect(Async::WebSocket::Client).to receive(:connect).once.and_call_original
      client = client_for('wss://nwc-ruby-test.invalid')

      expect { client.pay_invoice(invoice: invoice) }.to raise_error(NwcRuby::NotSentError)
    end

    it 'wraps connection refused during call as NotSentError' do
      client = client_for(refused_url)
      client.instance_variable_set(:@info, full_info)

      expect { client.pay_invoice(invoice: invoice) }.to raise_error(NwcRuby::NotSentError) { |e|
        expect(e.cause).to be_a(Errno::ECONNREFUSED)
      }
    end

    it 'wraps a TLS handshake failure as NotSentError' do
      # Answers the ClientHello with plaintext HTTP, as a misconfigured proxy would.
      server = TCPServer.new('127.0.0.1', 0)
      thread = Thread.new do
        loop do
          sock = server.accept
          sock.write("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
          sock.close
        end
      end
      client = client_for("wss://127.0.0.1:#{server.addr[1]}")

      expect { client.info }.to raise_error(NwcRuby::NotSentError) { |e|
        expect(e.cause).to be_a(OpenSSL::SSL::SSLError)
      }
    ensure
      thread&.kill
      server&.close
    end

    it 'treats a timeout during the websocket handshake as NotSentError' do
      server  = TCPServer.new('127.0.0.1', 0)
      held    = []
      thread  = Thread.new { loop { held << server.accept } }
      client  = client_for("ws://127.0.0.1:#{server.addr[1]}", request_timeout: 0.5)
      client.instance_variable_set(:@info, full_info)

      expect { client.pay_invoice(invoice: invoice) }.to raise_error(NwcRuby::NotSentError) { |e|
        expect(e.cause).to be_a(Async::TimeoutError)
        expect(e).not_to be_a(NwcRuby::TimeoutError)
        expect(e.sent?).to be false
      }
    ensure
      thread&.kill
      held&.each(&:close)
      server&.close
    end

    it 'raises InfoUnavailableError when the relay holds no info event' do
      with_relay(publish_info: false) do |relay|
        expect { client_for(relay.url).pay_invoice(invoice: invoice) }
          .to raise_error(NwcRuby::InfoUnavailableError)
        expect(relay.request_events).to be_empty
      end
    end

    it 'raises UnsupportedMethodError without connecting' do
      client = client_for(refused_url)
      client.instance_variable_set(
        :@info, NwcRuby::NIP47::Info.new(methods: ['get_balance'], encryption_schemes: ['nip44_v2'],
                                         notification_types: [], event: nil)
      )
      expect(Async::WebSocket::Client).not_to receive(:connect)

      expect { client.pay_invoice(invoice: invoice) }.to raise_error(NwcRuby::UnsupportedMethodError) { |e|
        expect(e.sent?).to be false
      }
    end

    it 'does not leave Async logging an unhandled task exception' do
      client = client_for(refused_url)

      expect do
        expect { client.info }.to raise_error(NwcRuby::NotSentError)
      end.not_to output(/unhandled exception/i).to_stderr_from_any_process
    end
  end

  describe 'post-send failures' do
    it 'returns the result on success, writing the EVENT once' do
      with_relay do |relay|
        expect(client_for(relay.url).pay_invoice(invoice: invoice)).to eq('preimage' => 'ab' * 32)
        expect(relay.request_events.size).to eq(1)
      end
    end

    it 'raises TransportError, not NotSentError, when the relay closes after the EVENT' do
      with_relay(behaviour: :close) do |relay|
        expect { client_for(relay.url, connect_retries: 2).pay_invoice(invoice: invoice) }
          .to raise_error(NwcRuby::TransportError) { |e|
            expect(e).not_to be_a(NwcRuby::NotSentError)
            expect(e.sent?).to be true
          }
        expect(relay.request_events.size).to eq(1)
      end
    end

    it 'raises TimeoutError, not NotSentError, when no response arrives after the EVENT' do
      with_relay(behaviour: :silent) do |relay|
        client = client_for(relay.url, request_timeout: 1, connect_retries: 2)
        client.info

        expect { client.pay_invoice(invoice: invoice) }.to raise_error(NwcRuby::TimeoutError) { |e|
          expect(e.cause).to be_a(Async::TimeoutError)
        }
        expect(relay.request_events.size).to eq(1)
      end
    end

    it 'raises WalletServiceError for a wallet error response' do
      with_relay(behaviour: :error) do |relay|
        expect { client_for(relay.url).pay_invoice(invoice: invoice) }
          .to raise_error(NwcRuby::WalletServiceError) { |e| expect(e.code).to eq('INSUFFICIENT_BALANCE') }
      end
    end

    it 'raises TransportError at once, without waiting out the timeout, when the relay rejects the EVENT' do
      with_relay(behaviour: :reject) do |relay|
        client = client_for(relay.url, request_timeout: 10, connect_retries: 2)
        client.info
        started = Async::Clock.now

        expect { client.pay_invoice(invoice: invoice) }.to raise_error(NwcRuby::TransportError) { |e|
          expect(e).not_to be_a(NwcRuby::NotSentError)
          expect(e.sent?).to be true
          expect(e.message).to include('blocked: rate-limited')
        }
        expect(Async::Clock.now - started).to be < 2
        expect(relay.request_events.size).to eq(1)
      end
    end

    # A wallet listening on both relays is not guaranteed to dedupe by event id,
    # so moving on to relay B after A took the EVENT could pay twice.
    %i[close reject silent].each do |behaviour|
      it "never falls back to the next relay once the EVENT was sent (#{behaviour})" do
        with_relay(behaviour: behaviour) do |first|
          with_relay do |second|
            client = client_for(first.url, second.url, request_timeout: 1, connect_retries: 2)
            client.info

            expect { client.pay_invoice(invoice: invoice) }.to raise_error(NwcRuby::Error) { |e|
              expect(e).not_to be_a(NwcRuby::NotSentError)
              expect(e.sent?).to be true
            }
            expect(first.request_events.size).to eq(1)
            expect(second.frames).to be_empty
          end
        end
      end
    end
  end

  describe 'pre-send retries' do
    it 'recovers from a transient DNS failure and writes the EVENT exactly once' do
      with_relay do |relay|
        client = client_for(relay.url, connect_retries: 2)
        client.info

        calls = 0
        allow(Async::WebSocket::Client).to receive(:connect).and_wrap_original do |original, *args, **kw, &blk|
          calls += 1
          raise dns_error, 'getaddrinfo: Name or service not known' if calls == 1

          original.call(*args, **kw, &blk)
        end

        expect(client.pay_invoice(invoice: invoice)).to include('preimage')
        expect(calls).to eq(2)
        expect(relay.request_events.size).to eq(1)
      end
    end

    it 'falls through to the next relay in the connection string' do
      with_relay do |relay|
        client = client_for(refused_url, relay.url)

        expect(client.pay_invoice(invoice: invoice)).to include('preimage')
        expect(relay.request_events.size).to eq(1)
      end
    end

    it 'gives up with NotSentError once retries are exhausted' do
      client = client_for(refused_url, connect_retries: 2)
      expect(Async::WebSocket::Client).to receive(:connect).exactly(3).times.and_call_original

      expect { client.info }.to raise_error(NwcRuby::NotSentError)
    end

    it 'keeps retries inside request_timeout' do
      client = client_for(refused_url, connect_retries: 10, request_timeout: 0.5)
      started = Async::Clock.now

      expect { client.info }.to raise_error(NwcRuby::NotSentError)
      expect(Async::Clock.now - started).to be < 1.5
    end
  end

  describe 'public API' do
    let(:low_level_errors) do
      [
        dns_error.new('getaddrinfo: Name or service not known'),
        Errno::ECONNREFUSED.new, Errno::ECONNRESET.new, Errno::EHOSTUNREACH.new, Errno::ETIMEDOUT.new,
        OpenSSL::SSL::SSLError.new('handshake failure'), Async::TimeoutError.new, EOFError.new, IOError.new,
        Protocol::WebSocket::ProtocolError.new('bad upgrade')
      ]
    end

    let(:public_calls) do
      {
        info: ->(c) { c.info(refresh: true) },
        capabilities: lambda(&:capabilities),
        read_only?: lambda(&:read_only?),
        pay_invoice: ->(c) { c.pay_invoice(invoice: invoice) },
        multi_pay_invoice: ->(c) { c.multi_pay_invoice(invoices: []) },
        pay_keysend: ->(c) { c.pay_keysend(amount: 1, pubkey: wallet_pub) },
        multi_pay_keysend: ->(c) { c.multi_pay_keysend(keysends: []) },
        make_invoice: ->(c) { c.make_invoice(amount: 1) },
        lookup_invoice: ->(c) { c.lookup_invoice(payment_hash: 'aa' * 32) },
        list_transactions: lambda(&:list_transactions),
        get_balance: lambda(&:get_balance),
        get_info: lambda(&:get_info),
        sign_message: ->(c) { c.sign_message(message: 'hi') }
      }
    end

    it 'raises only NotSentError when connecting fails, with the original as cause' do
      low_level_errors.each do |error|
        allow(Async::WebSocket::Client).to receive(:connect).and_raise(error)

        public_calls.each do |name, invoke|
          client = client_for('ws://relay.example.com')
          # Introspection only connects for the info fetch; the rest get past it.
          client.instance_variable_set(:@info, full_info) unless %i[info capabilities read_only?].include?(name)

          expect { invoke.call(client) }.to raise_error(NwcRuby::NotSentError) { |e|
            expect(e.cause).to be(error), "#{name} with #{error.class}"
          }
        end
      end
    end

    it 'raises only NwcRuby errors when the connection dies after sending' do
      low_level_errors.each do |error|
        conn = instance_double(Async::WebSocket::Connection, write: nil, flush: nil, close: nil)
        allow(conn).to receive(:read).and_raise(error)
        allow(Async::WebSocket::Client).to receive(:connect) { |_endpoint, &blk| blk.call(conn) }

        client = client_for('ws://relay.example.com')
        client.instance_variable_set(:@info, full_info)

        expect { client.pay_invoice(invoice: invoice) }.to raise_error(NwcRuby::Error) { |e|
          expect(e).not_to be_a(NwcRuby::NotSentError), error.class.name
          expect(e.cause).to be(error)
        }
      end
    end
  end
end
