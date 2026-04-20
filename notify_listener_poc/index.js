// nwc-listener — POC: long-lived subscription to NWC traffic on the relay.
// Usage: node index.js "nostr+walletconnect://<pubkey>?relay=wss://...&secret=..."

import WebSocket from "ws";
import { SimplePool, useWebSocketImplementation } from "nostr-tools/pool";
import { nip04 } from "nostr-tools";
import { nwc } from "@getalby/sdk";

// nostr-tools needs a WebSocket implementation under Node.
useWebSocketImplementation(WebSocket);

const nwcUrl = process.argv[2];
if (!nwcUrl || !nwcUrl.startsWith("nostr+walletconnect://")) {
  console.error('Usage: node index.js "nostr+walletconnect://..."');
  process.exit(1);
}

// Let the Alby SDK parse the NWC URL. NWCClient exposes the bits we need.
const client = new nwc.NWCClient({ nostrWalletConnectUrl: nwcUrl });
const relayUrl = client.relayUrls[0];
const walletPubkey = client.walletPubkey;
const secret = client.secret;
const clientPubkey = client.publicKey; // derived from secret
const secretBytes = Buffer.from(secret, "hex"); // nip04 wants Uint8Array

console.log("--- NWC listener ---");
console.log("relay:     ", relayUrl);
console.log("wallet pk: ", walletPubkey);
console.log("client pk: ", clientPubkey);
console.log("--------------------\n");

// enablePing + enableReconnect keeps the socket healthy over long runs.
const pool = new SimplePool({ enablePing: true, enableReconnect: true });

// Long-lived subscription. SimplePool holds the WebSocket open and invokes
// onevent for every matching event as it arrives — no polling.
const sub = pool.subscribeMany(
  [relayUrl],
  [
    {
      // NIP-47 kinds:
      //   23194 = request       (app    -> wallet)
      //   23195 = response      (wallet -> app)
      //   23196 = notification  (wallet -> app, legacy NIP-04)
      //   23197 = notification  (wallet -> app, NIP-44)
      kinds: [23194, 23195, 23196, 23197],
      "#p": [clientPubkey],
    },
  ],
  {
    async onevent(event) {
      console.log("=== event ===");
      console.log("id:        ", event.id);
      console.log("kind:      ", event.kind);
      console.log("author:    ", event.pubkey);
      console.log(
        "created_at:",
        new Date(event.created_at * 1000).toISOString(),
      );
      console.log("tags:      ", JSON.stringify(event.tags));

      // NWC payloads are encrypted between client and wallet. The same
      // keypair decrypts traffic in either direction, so we just pick
      // whichever pubkey is the counterparty.
      try {
        const counterparty =
          event.pubkey === clientPubkey ? walletPubkey : event.pubkey;
        const plaintext = await nip04.decrypt(
          secretBytes,
          counterparty,
          event.content,
        );
        console.log("content:   ", plaintext);
      } catch (err) {
        console.log("content:    [could not decrypt]", event.content);
      }
      console.log();
    },
    oneose() {
      console.log("[eose — historical sync done, now streaming live events]\n");
    },
    onclose(reasons) {
      console.log("[subscription closed]", reasons);
    },
  },
);

// Keep the process alive; shut down cleanly on Ctrl+C.
process.on("SIGINT", () => {
  console.log("\nshutting down...");
  sub.close();
  pool.close([relayUrl]);
  process.exit(0);
});
