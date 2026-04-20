# frozen_string_literal: true

RSpec.describe NostrWalletConnect::ConnectionString do
  let(:wallet_pubkey) { 'b889ff5b1513b641e2a139f661a661364979c5beee91842f8f0ef42ab558e9d4' }
  let(:secret)        { '71a8c14c1407c113601079c4302dab36460f0ccd0ad506f1f2dc73b5100e4f3c' }

  def build(params_hash = {})
    defaults = { 'relay' => ['wss://relay.example.com'], 'secret' => [secret] }
    params   = defaults.merge(params_hash) { |_, _old, new| Array(new) }
    query    = params.flat_map { |k, vs| Array(vs).map { |v| "#{k}=#{v}" } }.join('&')
    "nostr+walletconnect://#{wallet_pubkey}?#{query}"
  end

  it 'parses a minimal valid URI' do
    cs = described_class.parse(build)
    expect(cs.wallet_pubkey).to eq(wallet_pubkey)
    expect(cs.relays).to eq(['wss://relay.example.com'])
    expect(cs.secret).to eq(secret)
    expect(cs.lud16).to be_nil
  end

  it 'derives the client pubkey from the secret' do
    cs = described_class.parse(build)
    expect(cs.client_pubkey).to match(/\A[0-9a-f]{64}\z/)
  end

  it 'supports multiple relays' do
    cs = described_class.parse(build('relay' => %w[wss://a.example wss://b.example]))
    expect(cs.relays).to eq(%w[wss://a.example wss://b.example])
  end

  it 'rejects missing wallet pubkey' do
    expect do
      described_class.parse("nostr+walletconnect://?relay=wss://a&secret=#{secret}")
    end.to raise_error(NostrWalletConnect::InvalidConnectionStringError)
  end

  it 'rejects non-hex wallet pubkey' do
    bad_uri = "nostr+walletconnect://zzzzzzzz?relay=wss://a&secret=#{secret}"
    expect do
      described_class.parse(bad_uri)
    end.to raise_error(NostrWalletConnect::InvalidConnectionStringError)
  end

  it 'rejects missing relay' do
    uri = "nostr+walletconnect://#{wallet_pubkey}?secret=#{secret}"
    expect do
      described_class.parse(uri)
    end.to raise_error(NostrWalletConnect::InvalidConnectionStringError, /relay/)
  end

  it 'rejects non-hex secret' do
    expect do
      described_class.parse(build('secret' => ['not-hex']))
    end.to raise_error(NostrWalletConnect::InvalidConnectionStringError)
  end

  it 'rejects the wrong scheme' do
    expect do
      described_class.parse("https://#{wallet_pubkey}?relay=wss://a&secret=#{secret}")
    end.to raise_error(NostrWalletConnect::InvalidConnectionStringError)
  end

  it 'preserves lud16 when present' do
    cs = described_class.parse(build('lud16' => ['user@example.com']))
    expect(cs.lud16).to eq('user@example.com')
  end
end
