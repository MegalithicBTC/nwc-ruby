# frozen_string_literal: true

RSpec.describe NostrWalletConnect::NIP47::Notification do
  let(:client_priv) { NostrWalletConnect::Crypto::Keys.generate_private_key }
  let(:wallet_priv) { NostrWalletConnect::Crypto::Keys.generate_private_key }
  let(:client_pub)  { NostrWalletConnect::Crypto::Keys.public_key_from_private(client_priv) }
  let(:wallet_pub)  { NostrWalletConnect::Crypto::Keys.public_key_from_private(wallet_priv) }

  let(:notification_payload) do
    {
      "notification_type" => "payment_received",
      "notification"      => {
        "type" => "incoming", "state" => "settled",
        "invoice" => "lnbc100n1...", "preimage" => "f" * 64,
        "payment_hash" => "a" * 64, "amount" => 1_234,
        "fees_paid" => 0, "created_at" => 1, "expires_at" => 3_601,
        "settled_at" => 2, "metadata" => {}
      }
    }.to_json
  end

  it "parses a kind 23197 (NIP-44 v2) notification" do
    ct = NostrWalletConnect::NIP44::Cipher.encrypt(notification_payload, wallet_priv, client_pub)
    event = NostrWalletConnect::Event.new(
      pubkey: wallet_pub,
      kind:   NostrWalletConnect::NIP47::Methods::KIND_NOTIFICATION_NIP44,
      tags:   [["p", client_pub]],
      content: ct
    ).sign!(wallet_priv)

    notification = described_class.parse(event, client_priv, wallet_pub)
    expect(notification.type).to eq("payment_received")
    expect(notification.payment_hash).to eq("a" * 64)
    expect(notification.amount_msats).to eq(1_234)
    expect(notification.payment_received?).to be true
  end

  it "parses a kind 23196 (NIP-04) notification" do
    ct = NostrWalletConnect::NIP04::Cipher.encrypt(notification_payload, wallet_priv, client_pub)
    event = NostrWalletConnect::Event.new(
      pubkey:  wallet_pub,
      kind:    NostrWalletConnect::NIP47::Methods::KIND_NOTIFICATION_NIP04,
      tags:    [["p", client_pub]],
      content: ct
    ).sign!(wallet_priv)

    notification = described_class.parse(event, client_priv, wallet_pub)
    expect(notification.type).to eq("payment_received")
    expect(notification.payment_hash).to eq("a" * 64)
  end
end
