# frozen_string_literal: true

# End-to-end unit test that simulates the wallet service responding — exercises
# Request.build, Event signing, decryption on the wallet side, response signing
# on the wallet side, and Response.parse on the client side.
RSpec.describe "NIP-47 request/response round-trip" do
  let(:client_priv) { NostrWalletConnect::Crypto::Keys.generate_private_key }
  let(:wallet_priv) { NostrWalletConnect::Crypto::Keys.generate_private_key }
  let(:client_pub)  { NostrWalletConnect::Crypto::Keys.public_key_from_private(client_priv) }
  let(:wallet_pub)  { NostrWalletConnect::Crypto::Keys.public_key_from_private(wallet_priv) }

  %i[nip44_v2 nip04].each do |enc|
    context "with #{enc}" do
      it "round-trips a successful make_invoice response" do
        # Client builds request
        req_event = NostrWalletConnect::NIP47::Request.build(
          method:         "make_invoice",
          params:         { "amount" => 1_000 },
          client_privkey: client_priv,
          wallet_pubkey:  wallet_pub,
          encryption:     enc
        )
        expect(req_event.valid_signature?).to be true

        # Wallet decrypts the request
        inbound_plaintext =
          if enc == :nip44_v2
            NostrWalletConnect::NIP44::Cipher.decrypt(req_event.content, wallet_priv, client_pub)
          else
            NostrWalletConnect::NIP04::Cipher.decrypt(req_event.content, wallet_priv, client_pub)
          end
        inbound = JSON.parse(inbound_plaintext)
        expect(inbound["method"]).to eq("make_invoice")
        expect(inbound["params"]).to eq({ "amount" => 1_000 })

        # Wallet builds a response
        response_payload = {
          "result_type" => "make_invoice",
          "result"      => {
            "type" => "incoming", "state" => "pending",
            "invoice" => "lnbc10n1...", "payment_hash" => "a" * 64,
            "amount" => 1_000, "created_at" => 1, "expires_at" => 3_601
          },
          "error"       => nil
        }
        response_ct =
          if enc == :nip44_v2
            NostrWalletConnect::NIP44::Cipher.encrypt(response_payload.to_json, wallet_priv, client_pub)
          else
            NostrWalletConnect::NIP04::Cipher.encrypt(response_payload.to_json, wallet_priv, client_pub)
          end

        response_event = NostrWalletConnect::Event.new(
          pubkey: wallet_pub,
          kind:   NostrWalletConnect::NIP47::Methods::KIND_RESPONSE,
          tags:   [["p", client_pub], ["e", req_event.id]],
          content: response_ct
        ).sign!(wallet_priv)

        # Client parses the response
        parsed = NostrWalletConnect::NIP47::Response.parse(response_event, client_priv, wallet_pub)
        expect(parsed.success?).to be true
        expect(parsed.result["invoice"]).to eq("lnbc10n1...")
        expect(parsed.request_id).to eq(req_event.id)
      end

      it "parses an error response" do
        response_payload = {
          "result_type" => "pay_invoice",
          "result"      => nil,
          "error"       => { "code" => "INSUFFICIENT_BALANCE", "message" => "not enough sats" }
        }
        response_ct =
          if enc == :nip44_v2
            NostrWalletConnect::NIP44::Cipher.encrypt(response_payload.to_json, wallet_priv, client_pub)
          else
            NostrWalletConnect::NIP04::Cipher.encrypt(response_payload.to_json, wallet_priv, client_pub)
          end

        response_event = NostrWalletConnect::Event.new(
          pubkey:  wallet_pub,
          kind:    NostrWalletConnect::NIP47::Methods::KIND_RESPONSE,
          tags:    [["p", client_pub], ["e", "fake-request-id"]],
          content: response_ct
        ).sign!(wallet_priv)

        parsed = NostrWalletConnect::NIP47::Response.parse(response_event, client_priv, wallet_pub)
        expect(parsed.success?).to be false
        expect(parsed.error_code).to eq("INSUFFICIENT_BALANCE")
      end
    end
  end
end
