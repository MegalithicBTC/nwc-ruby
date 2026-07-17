# frozen_string_literal: true

# Guards applied to every event a relay hands us. The relay is untrusted: it
# chooses what to send regardless of the REQ filter, so each of these checks
# stands on its own rather than on the filter being honoured.
RSpec.describe NwcRuby::Client do
  let(:wallet_priv) { NwcRuby::Crypto::Keys.generate_private_key }
  let(:wallet_pub)  { NwcRuby::Crypto::Keys.public_key_from_private(wallet_priv) }
  let(:client_priv) { NwcRuby::Crypto::Keys.generate_private_key }
  let(:client_pub)  { NwcRuby::Crypto::Keys.public_key_from_private(client_priv) }

  let(:client) do
    described_class.from_uri(
      "nostr+walletconnect://#{wallet_pub}?relay=wss://relay.example.com&secret=#{client_priv}"
    )
  end

  # A genuine, wallet-signed response to `request_id`.
  def wallet_response(request_id:, kind: NwcRuby::NIP47::Methods::KIND_RESPONSE, privkey: wallet_priv)
    pubkey = NwcRuby::Crypto::Keys.public_key_from_private(privkey)
    NwcRuby::Event.new(
      pubkey: pubkey,
      kind: kind,
      content: NwcRuby::NIP44::Cipher.encrypt(
        JSON.generate({ 'result_type' => 'pay_invoice', 'result' => { 'preimage' => 'ab' * 32 } }),
        privkey, client_pub
      ),
      tags: [['p', client_pub], ['e', request_id]]
    ).sign!(privkey)
  end

  describe 'authentic?' do
    it 'accepts a genuine event from the wallet' do
      event = wallet_response(request_id: 'a' * 64)
      expect(client.send(:authentic?, event)).to be true
    end

    it 'rejects a validly-signed event from a pubkey other than the wallet' do
      # The relay signs with its own key. The signature is perfectly valid; it
      # is simply not the wallet's.
      impostor = NwcRuby::Crypto::Keys.generate_private_key
      event    = wallet_response(request_id: 'a' * 64, privkey: impostor)

      expect(event.valid_signature?).to be true
      expect(client.send(:authentic?, event)).to be false
    end

    it 'rejects a wallet event whose body was altered after signing' do
      event = wallet_response(request_id: 'a' * 64)
      event.content = 'tampered'

      expect(client.send(:authentic?, event)).to be false
    end
  end

  # Drives the real on_event callback installed by subscribe_to_notifications,
  # so the guards are exercised where they actually run.
  describe 'the notification listener' do
    let(:fake_conn) do
      Class.new do
        def initialize = @cbs = {}
        def on_open(&blk)  = @cbs[:open] = blk
        def on_poll(&blk)  = @cbs[:poll] = blk
        def on_event(&blk) = @cbs[:event] = blk
        def run! = nil
        def emit(hash) = @cbs[:event].call('sub', hash)
      end.new
    end

    def notification_event(kind:, privkey: wallet_priv)
      pubkey  = NwcRuby::Crypto::Keys.public_key_from_private(privkey)
      payload = JSON.generate(
        { 'notification_type' => 'payment_received',
          'notification' => { 'payment_hash' => 'aa' * 32, 'amount' => 1_000 } }
      )
      cipher = kind == NwcRuby::NIP47::Methods::KIND_NOTIFICATION_NIP44 ? NwcRuby::NIP44::Cipher : NwcRuby::NIP04::Cipher
      NwcRuby::Event.new(
        pubkey: pubkey, kind: kind,
        content: cipher.encrypt(payload, privkey, client_pub),
        tags: [['p', client_pub]]
      ).sign!(privkey)
    end

    before { allow(NwcRuby::Transport::RelayConnection).to receive(:new).and_return(fake_conn) }

    def listen
      received = []
      client.subscribe_to_notifications { |n| received << n }
      received
    end

    it 'delivers a genuine wallet notification' do
      received = listen
      fake_conn.emit(notification_event(kind: NwcRuby::NIP47::Methods::KIND_NOTIFICATION_NIP44).to_h)

      expect(received.map(&:type)).to eq(['payment_received'])
    end

    it 'drops a notification grafted onto a genuine id and sig' do
      received = listen
      genuine  = notification_event(kind: NwcRuby::NIP47::Methods::KIND_NOTIFICATION_NIP44).to_h
      # A relay rewriting created_at would otherwise poison the poll watermark.
      fake_conn.emit(genuine.merge('created_at' => genuine['created_at'] + 86_400))

      expect(received).to be_empty
    end

    it 'ignores a response event echoed back on the notification subscription' do
      # Notification.parse raises ArgumentError on kind 23195; unrescued, that
      # would tear the listener down rather than skip the event.
      received = listen

      expect { fake_conn.emit(wallet_response(request_id: 'a' * 64).to_h) }.not_to raise_error
      expect(received).to be_empty
    end
  end

  describe 'response_to?' do
    it 'accepts a response carrying the matching e tag' do
      event = wallet_response(request_id: 'f' * 64)
      expect(client.send(:response_to?, event, 'f' * 64)).to be true
    end

    it 'rejects a genuine response replayed against a different request' do
      # The core replay: a real, correctly signed wallet response to some
      # earlier request (e.g. a past "payment succeeded") fed to a new one.
      stale = wallet_response(request_id: 'a' * 64)

      expect(client.send(:authentic?, stale)).to be true
      expect(client.send(:response_to?, stale, 'b' * 64)).to be false
    end

    it 'rejects a response with no e tag at all' do
      event = NwcRuby::Event.new(
        pubkey: wallet_pub, kind: NwcRuby::NIP47::Methods::KIND_RESPONSE,
        content: 'x', tags: [['p', client_pub]]
      ).sign!(wallet_priv)

      expect(client.send(:response_to?, event, 'b' * 64)).to be false
    end
  end
end
