# frozen_string_literal: true

RSpec.describe NwcRuby::NIP47::Info do
  def build_event(content:, tags: [])
    NwcRuby::Event.from_hash(
      'pubkey' => 'a' * 64,
      'kind' => 13_194,
      'content' => content,
      'tags' => tags,
      'created_at' => 1,
      'id' => 'id',
      'sig' => 'sig'
    )
  end

  it 'parses a minimal read-only info event' do
    ev   = build_event(content: 'get_info get_balance make_invoice lookup_invoice')
    info = described_class.parse(ev)
    expect(info.methods).to contain_exactly('get_info', 'get_balance', 'make_invoice', 'lookup_invoice')
    expect(info.read_only?).to be true
    expect(info.read_write?).to be false
    expect(info.supports?('pay_invoice')).to be false
  end

  it 'parses a read+write info event' do
    ev = build_event(content: 'pay_invoice make_invoice lookup_invoice get_balance get_info')
    info = described_class.parse(ev)
    expect(info.read_write?).to be true
    expect(info.read_only?).to be false
  end

  it 'defaults encryption to nip04 when tag is absent' do
    ev   = build_event(content: 'get_info')
    info = described_class.parse(ev)
    expect(info.encryption_schemes).to eq(['nip04'])
    expect(info.preferred_encryption).to eq(:nip04)
  end

  it 'prefers nip44_v2 when advertised' do
    ev   = build_event(content: 'get_info', tags: [['encryption', 'nip44_v2 nip04']])
    info = described_class.parse(ev)
    expect(info.supports_nip44?).to be true
    expect(info.preferred_encryption).to eq(:nip44_v2)
  end

  it 'parses notifications tag' do
    ev = build_event(
      content: 'get_info',
      tags: [['notifications', 'payment_received payment_sent']]
    )
    info = described_class.parse(ev)
    expect(info.notification_types).to eq(%w[payment_received payment_sent])
    expect(info.supports_notifications?).to be true
  end

  it 'handles multi-whitespace method lists' do
    ev = build_event(content: "  get_info    get_balance\n\nmake_invoice  ")
    info = described_class.parse(ev)
    expect(info.methods).to contain_exactly('get_info', 'get_balance', 'make_invoice')
  end
end
