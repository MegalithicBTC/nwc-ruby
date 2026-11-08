# frozen_string_literal: true

require 'digest'
require 'json'

# The official NIP-44 v2 test vectors from github.com/paulmillr/nip44
# (nip44.vectors.json), vendored unmodified. NIP-44 publishes the file's
# SHA-256, checked first so an edited copy cannot pass silently.
RSpec.describe 'NIP-44 v2 official vectors' do
  path = File.expand_path('../fixtures/nip44.vectors.json', __dir__)
  vectors = JSON.parse(File.read(path))['v2']

  it 'uses the unmodified vector file' do
    expect(Digest::SHA256.file(path).hexdigest)
      .to eq('269ed0f69e4c192512cc779e78c555090cebc7c785b609e338a62afc3ce25040')
  end

  describe 'valid.get_conversation_key' do
    vectors['valid']['get_conversation_key'].each_with_index do |v, i|
      it "##{i + 1}#{" (#{v['note']})" if v['note']}" do
        conversation = NwcRuby::Crypto::Conversation.new(v['sec1'], v['pub2'])
        expect(conversation.nip44_key.unpack1('H*')).to eq(v['conversation_key'])
      end
    end
  end

  describe 'invalid.get_conversation_key' do
    vectors['invalid']['get_conversation_key'].each do |v|
      it "rejects #{v['note']}" do
        conversation = NwcRuby::Crypto::Conversation.new(v['sec1'], v['pub2'])
        expect { conversation.nip44_key }.to raise_error(NwcRuby::EncryptionError)
      end
    end
  end

  describe 'valid.encrypt_decrypt' do
    vectors['valid']['encrypt_decrypt'].each_with_index do |v, i|
      it "##{i + 1}" do
        pub1 = NwcRuby::Crypto::Keys.public_key_from_private(v['sec1'])
        pub2 = NwcRuby::Crypto::Keys.public_key_from_private(v['sec2'])
        alice = NwcRuby::Crypto::Conversation.new(v['sec1'], pub2)
        bob   = NwcRuby::Crypto::Conversation.new(v['sec2'], pub1)

        expect(alice.nip44_key.unpack1('H*')).to eq(v['conversation_key'])
        expect(bob.nip44_key).to eq(alice.nip44_key)
        nonce = [v['nonce']].pack('H*')
        expect(NwcRuby::NIP44::Cipher.encrypt_with(v['plaintext'], alice, nonce: nonce)).to eq(v['payload'])
        expect(NwcRuby::NIP44::Cipher.decrypt_with(v['payload'], bob)).to eq(v['plaintext'])
      end
    end
  end
end
