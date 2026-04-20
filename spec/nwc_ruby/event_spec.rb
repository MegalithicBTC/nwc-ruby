# frozen_string_literal: true

RSpec.describe NwcRuby::Event do
  let(:priv) { NwcRuby::Crypto::Keys.generate_private_key }
  let(:pub)  { NwcRuby::Crypto::Keys.public_key_from_private(priv) }

  it 'computes a stable event id' do
    event = described_class.new(pubkey: pub, kind: 1, content: 'gm', created_at: 1_700_000_000, tags: [])
    event.compute_id!
    # Manually compute expected id
    payload  = JSON.generate([0, pub, 1_700_000_000, 1, [], 'gm'])
    expected = OpenSSL::Digest::SHA256.hexdigest(payload)
    expect(event.id).to eq(expected)
  end

  it 'signs an event and verifies' do
    event = described_class.new(pubkey: pub, kind: 1, content: 'gm').sign!(priv)
    expect(event.sig).to match(/\A[0-9a-f]{128}\z/)
    expect(event.valid_signature?).to be true
  end

  it 'rejects a tampered event' do
    event = described_class.new(pubkey: pub, kind: 1, content: 'gm').sign!(priv)
    event.content = 'tampered'
    event.compute_id! # recompute id for new content, but sig still from old id
    expect(event.valid_signature?).to be false
  end

  it 'round-trips through to_h / from_hash' do
    e1 = described_class.new(pubkey: pub, kind: 1, content: 'gm').sign!(priv)
    e2 = described_class.from_hash(e1.to_h)
    expect(e2.valid_signature?).to be true
    expect(e2.id).to eq(e1.id)
  end
end
