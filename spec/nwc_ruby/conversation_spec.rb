# frozen_string_literal: true

require_relative '../support/fake_relay'

RSpec.describe NwcRuby::Crypto::Conversation do
  let(:alice_priv) { NwcRuby::Crypto::Keys.generate_private_key }
  let(:bob_priv)   { NwcRuby::Crypto::Keys.generate_private_key }
  let(:alice_pub)  { NwcRuby::Crypto::Keys.public_key_from_private(alice_priv) }
  let(:bob_pub)    { NwcRuby::Crypto::Keys.public_key_from_private(bob_priv) }

  describe 'keys' do
    # Authoritative vectors from github.com/paulmillr/nip44/blob/main/nip44.vectors.json
    it 'matches v2.valid.get_conversation_key #1' do
      conversation = described_class.new(
        '315e59ff51cb9209768cf7da80791ddcaae56ac9775eb25b6dee1234bc5d2268',
        'c2f9d9948dc8c7c38321e4b85c8558872eafa0641cd269db76848a6073e69133'
      )
      expect(conversation.nip44_key.unpack1('H*')).to eq(
        '3dfef0ce2a4d80a25e7a328accf73448ef67096f65f79588e358d9a0eb9013f1'
      )
    end

    it 'matches v2.valid.encrypt_decrypt #1 end to end' do
      sec1 = "#{'0' * 63}1"
      pub2 = NwcRuby::Crypto::Keys.public_key_from_private("#{'0' * 63}2")
      conversation = described_class.new(sec1, pub2)

      expect(conversation.nip44_key.unpack1('H*')).to eq(
        'c41c775356fd92eadc63ff5a0dc1da211b268cbea22316767095b2871ea1412d'
      )
      payload = 'AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABee0G5VSK0/9YypIObAtDKfYEAjD35uVkHyB0F4' \
                'DwrcNaCXlCWZKaArsGrY6M9wnuTMxWfp1RTN9Xga8no+kF5Vsb'
      nonce = ["#{'0' * 63}1"].pack('H*')
      expect(NwcRuby::NIP44::Cipher.encrypt_with('a', conversation, nonce: nonce)).to eq(payload)
      expect(NwcRuby::NIP44::Cipher.decrypt_with(payload, conversation)).to eq('a')
    end

    it 'derives the same keys as the uncached path' do
      conversation = described_class.new(alice_priv, bob_pub)

      expect(conversation.nip04_key).to eq(NwcRuby::Crypto::ECDH.shared_x(alice_priv, bob_pub))
      expect(conversation.nip44_key).to eq(NwcRuby::NIP44::Cipher.derive_conversation_key(alice_priv, bob_pub))
    end

    it 'gives both sides of a pair the same keys' do
      alice = described_class.new(alice_priv, bob_pub)
      bob   = described_class.new(bob_priv, alice_pub)

      expect(alice.nip04_key).to eq(bob.nip04_key)
      expect(alice.nip44_key).to eq(bob.nip44_key)
    end
  end

  describe 'caching' do
    it 'runs ECDH once across many messages in both schemes' do
      expect(NwcRuby::Crypto::ECDH).to receive(:shared_x).once.and_call_original
      conversation = described_class.new(alice_priv, bob_pub)

      3.times do |i|
        ct = NwcRuby::NIP44::Cipher.encrypt_with("nip44 #{i}", conversation)
        expect(NwcRuby::NIP44::Cipher.decrypt_with(ct, conversation)).to eq("nip44 #{i}")
        ct = NwcRuby::NIP04::Cipher.encrypt_with("nip04 #{i}", conversation)
        expect(NwcRuby::NIP04::Cipher.decrypt_with(ct, conversation)).to eq("nip04 #{i}")
      end
    end

    it 'still draws a fresh nonce for every NIP-44 message' do
      conversation = described_class.new(alice_priv, bob_pub)
      nonces = Array.new(3) do
        Base64.strict_decode64(NwcRuby::NIP44::Cipher.encrypt_with('same', conversation)).byteslice(1, 32)
      end

      expect(nonces.uniq.size).to eq(3)
    end

    it 'interoperates with the uncached cipher API' do
      conversation = described_class.new(alice_priv, bob_pub)

      ct = NwcRuby::NIP44::Cipher.encrypt_with('hello', conversation)
      expect(NwcRuby::NIP44::Cipher.decrypt(ct, bob_priv, alice_pub)).to eq('hello')
      ct = NwcRuby::NIP04::Cipher.encrypt('hello', bob_priv, alice_pub)
      expect(NwcRuby::NIP04::Cipher.decrypt_with(ct, conversation)).to eq('hello')
    end

    it 'does no work in new, so a bad key raises at first use and is not cached' do
      conversation = nil
      expect { conversation = described_class.new(alice_priv, 'not-hex') }.not_to raise_error

      2.times do
        expect { conversation.nip44_key }.to raise_error(NwcRuby::InvalidConnectionStringError)
      end
    end

    it 'rejects a malformed payload without running ECDH' do
      expect(NwcRuby::Crypto::ECDH).not_to receive(:shared_x)
      conversation = described_class.new(alice_priv, bob_pub)

      expect { NwcRuby::NIP47::Response.decrypt_with('not a payload', conversation) }
        .to raise_error(NwcRuby::EncryptionError)
    end
  end

  describe 'on a Client' do
    let(:wallet_priv) { NwcRuby::Crypto::Keys.generate_private_key }
    let(:wallet_pub)  { NwcRuby::Crypto::Keys.public_key_from_private(wallet_priv) }
    let(:client_priv) { NwcRuby::Crypto::Keys.generate_private_key }
    let(:client_pub)  { NwcRuby::Crypto::Keys.public_key_from_private(client_priv) }

    it 'runs the client-side ECDH once across several calls' do
      relay = FakeRelay.new(wallet_priv: wallet_priv, client_pub: client_pub).start
      client = NwcRuby::Client.from_uri(
        "nostr+walletconnect://#{wallet_pub}?relay=#{relay.url}&secret=#{client_priv}",
        logger: Logger.new(IO::NULL), request_timeout: 5
      )
      # Counted per key pair: the fake wallet runs its own ECDH
      # (wallet_priv, client_pub) on its thread, and that one is not ours.
      calls = Hash.new(0)
      allow(NwcRuby::Crypto::ECDH).to receive(:shared_x).and_wrap_original do |original, priv, pub|
        calls[[priv, pub]] += 1
        original.call(priv, pub)
      end

      3.times { expect(client.pay_invoice(invoice: 'lnbc10n1fake')).to include('preimage') }
      expect(calls[[client_priv, wallet_pub]]).to eq(1)
    ensure
      relay&.stop
    end
  end
end
