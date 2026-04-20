# frozen_string_literal: true

RSpec.describe NwcRuby::NIP44::Cipher do
  describe '.calc_padded_len' do
    # Authoritative vectors from github.com/paulmillr/nip44/blob/main/nip44.vectors.json
    # (v2.valid.calc_padded_len). These are the full set — do not invent extras.
    [
      [16, 32], [32, 32], [33, 64], [37, 64], [45, 64], [49, 64], [64, 64],
      [65, 96], [100, 128], [111, 128], [200, 224], [250, 256], [320, 320],
      [383, 384], [384, 384], [400, 448], [500, 512], [512, 512], [515, 640],
      [700, 768], [800, 896], [900, 1024], [1020, 1024], [65_536, 65_536]
    ].each do |unpadded, expected|
      it "pads #{unpadded} -> #{expected}" do
        expect(described_class.calc_padded_len(unpadded)).to eq(expected)
      end
    end
  end

  describe 'secure_compare' do
    it 'returns true for equal bytes' do
      expect(described_class.secure_compare('abc', 'abc')).to be true
    end

    it 'returns false for different-length inputs' do
      expect(described_class.secure_compare('abc', 'abcd')).to be false
    end

    it 'returns false for different content' do
      expect(described_class.secure_compare('abc', 'abd')).to be false
    end
  end

  describe 'HKDF' do
    # RFC 5869 test vector #1
    it 'passes RFC 5869 Test Case 1' do
      ikm  = ['0b' * 22].pack('H*')
      salt = ['000102030405060708090a0b0c'].pack('H*')
      info = ['f0f1f2f3f4f5f6f7f8f9'].pack('H*')

      prk = described_class.hkdf_extract(salt, ikm)
      expect(prk.unpack1('H*')).to eq(
        '077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5'
      )

      okm = described_class.hkdf_expand(prk, info, 42)
      expect(okm.unpack1('H*')).to eq(
        '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865'
      )
    end

    # Authoritative NIP-44 get_message_keys vectors from paulmillr/nip44.
    # The conversation_key is used as PRK for HKDF-expand(info=nonce, L=76),
    # and the first 32 / next 12 / last 32 bytes of the output are the
    # chacha_key / chacha_nonce / hmac_key respectively.
    describe 'get_message_keys (NIP-44 HKDF-expand)' do
      conv_key = 'a1a3d60f3470a8612633924e91febf96dc5366ce130f658b1f0fc652c20b3b54'

      [
        {
          nonce: 'e1e6f880560d6d149ed83dcc7e5861ee62a5ee051f7fde9975fe5d25d2a02d72',
          cc_key: 'f145f3bed47cb70dbeaac07f3a3fe683e822b3715edb7c4fe310829014ce7d76',
          cc_nonce: 'c4ad129bb01180c0933a160c',
          hmac_key: '027c1db445f05e2eee864a0975b0ddef5b7110583c8c192de3732571ca5838c4'
        },
        {
          nonce: 'e1d6d28c46de60168b43d79dacc519698512ec35e8ccb12640fc8e9f26121101',
          cc_key: 'e35b88f8d4a8f1606c5082f7a64b100e5d85fcdb2e62aeafbec03fb9e860ad92',
          cc_nonce: '22925e920cee4a50a478be90',
          hmac_key: '46a7c55d4283cb0df1d5e29540be67abfe709e3b2e14b7bf9976e6df994ded30'
        },
        {
          nonce: 'cfc13bef512ac9c15951ab00030dfaf2626fdca638dedb35f2993a9eeb85d650',
          cc_key: '020783eb35fdf5b80ef8c75377f4e937efb26bcbad0e61b4190e39939860c4bf',
          cc_nonce: 'd3594987af769a52904656ac',
          hmac_key: '237ec0ccb6ebd53d179fa8fd319e092acff599ef174c1fdafd499ef2b8dee745'
        }
      ].each_with_index do |v, i|
        it "matches vector ##{i + 1}" do
          prk      = [conv_key].pack('H*')
          info     = [v[:nonce]].pack('H*')
          expanded = described_class.hkdf_expand(prk, info, 76)
          expect(expanded[0, 32].unpack1('H*')).to  eq(v[:cc_key])
          expect(expanded[32, 12].unpack1('H*')).to eq(v[:cc_nonce])
          expect(expanded[44, 32].unpack1('H*')).to eq(v[:hmac_key])
        end
      end
    end
  end

  describe 'round-trip encryption' do
    let(:alice_priv) { NwcRuby::Crypto::Keys.generate_private_key }
    let(:bob_priv)   { NwcRuby::Crypto::Keys.generate_private_key }
    let(:alice_pub)  { NwcRuby::Crypto::Keys.public_key_from_private(alice_priv) }
    let(:bob_pub)    { NwcRuby::Crypto::Keys.public_key_from_private(bob_priv) }

    it 'round-trips a small message' do
      ct = described_class.encrypt('hello, world', alice_priv, bob_pub)
      pt = described_class.decrypt(ct, bob_priv, alice_pub)
      expect(pt).to eq('hello, world')
    end

    it 'round-trips a JSON payload (typical NWC shape)' do
      payload = { 'method' => 'make_invoice', 'params' => { 'amount' => 1_000 } }.to_json
      ct = described_class.encrypt(payload, alice_priv, bob_pub)
      pt = described_class.decrypt(ct, bob_priv, alice_pub)
      expect(pt).to eq(payload)
    end

    it 'round-trips a message near a padding boundary' do
      msg = 'A' * 33
      ct = described_class.encrypt(msg, alice_priv, bob_pub)
      pt = described_class.decrypt(ct, bob_priv, alice_pub)
      expect(pt).to eq(msg)
    end

    it 'round-trips a long message that spans multiple HKDF blocks' do
      msg = 'long message ' * 500
      ct = described_class.encrypt(msg, alice_priv, bob_pub)
      pt = described_class.decrypt(ct, bob_priv, alice_pub)
      expect(pt).to eq(msg)
    end

    it 'rejects a tampered MAC' do
      ct  = described_class.encrypt('hello', alice_priv, bob_pub)
      raw = Base64.strict_decode64(ct)
      raw.setbyte(raw.bytesize - 1, raw.getbyte(raw.bytesize - 1) ^ 0x01)
      tampered = Base64.strict_encode64(raw)
      expect do
        described_class.decrypt(tampered, bob_priv, alice_pub)
      end.to raise_error(NwcRuby::EncryptionError, /MAC/)
    end

    it 'rejects the wrong version byte' do
      ct  = described_class.encrypt('hello', alice_priv, bob_pub)
      raw = Base64.strict_decode64(ct)
      raw.setbyte(0, 0x99)
      tampered = Base64.strict_encode64(raw)
      expect do
        described_class.decrypt(tampered, bob_priv, alice_pub)
      end.to raise_error(NwcRuby::EncryptionError, /version/)
    end
  end
end
