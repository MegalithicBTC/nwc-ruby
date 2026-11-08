# frozen_string_literal: true

RSpec.describe NwcRuby::Crypto::ECDH do
  n = described_class::N
  p = described_class::P

  hex = ->(i) { i.to_s(16).rjust(64, '0') }
  # libsecp256k1 (via rbsecp256k1) as an independent reference: the x-only
  # public key of scalar d, i.e. x(d * G).
  ctx = Secp256k1::Context.create
  xonly = ->(d) { ctx.key_pair_from_private_key([hex.call(d)].pack('H*')).public_key.compressed[1, 32].unpack1('H*') }

  def random_scalar(rng, leading_zero_bytes = 0)
    loop do
      bytes = rng.bytes(32)
      bytes[0, leading_zero_bytes] = "\0" * leading_zero_bytes
      d = bytes.unpack1('H*').to_i(16)
      return d if d.positive? && d < described_class::N
    end
  end

  let(:rng) { Random.new(RSpec.configuration.seed) }

  describe '.shared_x' do
    # ECDH(a, x(b*G)) has the X coordinate of (a*b)*G whichever sign lift_x
    # picks for the peer, so x((a*b mod n) * G) is the expected answer.
    it 'matches libsecp256k1 point multiplication on random pairs' do
      200.times do |i|
        a = random_scalar(rng, i % 4) # every 4th key starts with 0, 1, 2, 3 zero bytes
        b = random_scalar(rng)
        expect(described_class.shared_x(hex.call(a), xonly.call(b)).unpack1('H*')).to eq(xonly.call((a * b) % n))
      end
    end

    it 'returns 32 binary bytes' do
      x = described_class.shared_x(hex.call(random_scalar(rng)), xonly.call(random_scalar(rng)))
      expect(x.bytesize).to eq(32)
      expect(x.encoding).to eq(Encoding::BINARY)
    end

    it 'is symmetric' do
      a = random_scalar(rng)
      b = random_scalar(rng)
      ours   = described_class.shared_x(hex.call(a), xonly.call(b))
      theirs = described_class.shared_x(hex.call(b), xonly.call(a))
      expect(ours).to eq(theirs)
    end

    # The smallest scalars c whose x(c * G) starts with one / two zero bytes.
    {
      153 => '00e3ae1974566ca06cc516d47e0fb165a674a3dabcfca15e722f0e3450f45889',
      44_629 => '00008f2eca2314ee8bf0c03549e442ff21f750d8f7332bc6f2abc9980aabe9b0'
    }.each do |c, x_hex|
      it "keeps the leading zero bytes of a shared X (#{x_hex[0, 8]}...)" do
        expect(xonly.call(c)).to eq(x_hex)
        # Directly: a private key that is mostly leading zeros, times G.
        expect(described_class.shared_x(hex.call(c), described_class::GX_HEX).unpack1('H*')).to eq(x_hex)

        # Split across a random pair: a * b = c (mod n).
        a = random_scalar(rng)
        b = (c * a.pow(n - 2, n)) % n
        [[a, b], [b, a]].each do |ours, theirs|
          x = described_class.shared_x(hex.call(ours), xonly.call(theirs))
          expect(x.bytesize).to eq(32)
          expect(x.unpack1('H*')).to eq(x_hex)
        end
      end
    end

    # OpenSSL 3.5 also reads a short octet string correctly, so the results
    # above would not catch a key that lost its leading zeros. RFC 5915 fixes
    # the length at 32 bytes; check the encoding itself.
    it 'encodes the private key as exactly 32 bytes, leading zeros included' do
      der = described_class.private_key_der(["#{'0' * 62}99"].pack('H*'))
      expect(OpenSSL::ASN1.decode(der).value[1].value).to eq(["#{'0' * 62}99"].pack('H*'))
    end

    it 'encodes the peer as the even-Y compressed point 02 || x' do
      x = [xonly.call(random_scalar(rng))].pack('H*')
      der = described_class.public_key_der(x)
      expect(OpenSSL::ASN1.decode(der).value[1].value).to eq("\x02".b + x)
    end

    it 'accepts the edges of the private key range' do
      peer = random_scalar(rng)
      [1, 2, n - 2, n - 1].each do |d|
        expect(described_class.shared_x(hex.call(d), xonly.call(peer)).unpack1('H*')).to eq(xonly.call((d * peer) % n))
      end
    end

    describe 'invalid input' do
      let(:valid_priv) { hex.call(random_scalar(rng)) }
      let(:valid_pub)  { xonly.call(random_scalar(rng)) }

      {
        'x = 0' => [hex.call(0), 'x out of range'],
        'x = p' => [hex.call(p), 'x out of range'],
        'x = p + 1' => [hex.call(p + 1), 'x out of range'],
        'x = 2^256 - 1' => ['f' * 64, 'x out of range'],
        # x^3 + 7 has no square root mod p for these, so no curve point.
        'off-curve x = 1234...' => ['1234567890abcdef' * 4, 'x is not on the curve'],
        'off-curve x on the twist (order 13)' => ['eb1f7200aecaa86682376fb1c13cd12b732221e774f553b0a0857f88fa20f86d',
                                                  'x is not on the curve']
      }.each do |label, (pub, message)|
        it "rejects a public key with #{label}" do
          expect { described_class.shared_x(valid_priv, pub) }
            .to raise_error(NwcRuby::EncryptionError, message)
        end
      end

      {
        'private key 0' => 0,
        'private key n' => n,
        'private key n + 1' => n + 1,
        'private key 2^256 - 1' => (2**256) - 1
      }.each do |label, d|
        it "rejects #{label}" do
          expect { described_class.shared_x(hex.call(d), valid_pub) }
            .to raise_error(NwcRuby::EncryptionError, 'private key out of range')
        end
      end

      it 'rejects keys that are not 64 hex characters' do
        expect { described_class.shared_x('zz' * 32, valid_pub) }.to raise_error(NwcRuby::InvalidConnectionStringError)
        expect { described_class.shared_x(valid_priv, 'ab' * 31) }.to raise_error(NwcRuby::InvalidConnectionStringError)
      end

      it 'does not cache a failure on a Conversation' do
        conversation = NwcRuby::Crypto::Conversation.new(valid_priv, '1234567890abcdef' * 4)
        expect(described_class).to receive(:shared_x).twice.and_call_original

        2.times do
          expect { conversation.nip44_key }.to raise_error(NwcRuby::EncryptionError, 'x is not on the curve')
        end
      end
    end
  end

  describe 'when OpenSSL lacks secp256k1' do
    around do |example|
      described_class.instance_variable_set(:@available, nil)
      example.run
    ensure
      described_class.instance_variable_set(:@available, nil)
    end

    it 'is available on this OpenSSL' do
      expect(described_class.available?).to be(true)
    end

    it 'reports unavailable when OpenSSL cannot load the curve' do
      allow(OpenSSL::PKey).to receive(:read).and_raise(OpenSSL::PKey::PKeyError, 'unsupported')
      expect(described_class.available?).to be(false)
    end

    it 'raises CryptoUnavailableError, which is not an EncryptionError' do
      allow(described_class).to receive(:available?).and_return(false)

      expect { described_class.shared_x(hex.call(random_scalar(rng)), xonly.call(random_scalar(rng))) }
        .to raise_error(NwcRuby::CryptoUnavailableError, /secp256k1/) { |e|
          expect(e).not_to be_a(NwcRuby::EncryptionError)
        }
    end
  end
end
