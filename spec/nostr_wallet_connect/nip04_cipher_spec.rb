# frozen_string_literal: true

RSpec.describe NostrWalletConnect::NIP04::Cipher do
  let(:alice_priv) { NostrWalletConnect::Crypto::Keys.generate_private_key }
  let(:bob_priv)   { NostrWalletConnect::Crypto::Keys.generate_private_key }
  let(:alice_pub)  { NostrWalletConnect::Crypto::Keys.public_key_from_private(alice_priv) }
  let(:bob_pub)    { NostrWalletConnect::Crypto::Keys.public_key_from_private(bob_priv) }

  it 'round-trips a payload' do
    ct = described_class.encrypt('secret message', alice_priv, bob_pub)
    pt = described_class.decrypt(ct, bob_priv, alice_pub)
    expect(pt).to eq('secret message')
  end

  it 'produces a different ciphertext each time (random IV)' do
    ct1 = described_class.encrypt('hello', alice_priv, bob_pub)
    ct2 = described_class.encrypt('hello', alice_priv, bob_pub)
    expect(ct1).not_to eq(ct2)
  end

  it 'uses the ?iv= payload format' do
    ct = described_class.encrypt('hello', alice_priv, bob_pub)
    expect(ct).to include('?iv=')
  end

  it 'rejects malformed payloads' do
    expect do
      described_class.decrypt('not-a-nip04-payload', alice_priv, bob_pub)
    end.to raise_error(NostrWalletConnect::EncryptionError)
  end
end
