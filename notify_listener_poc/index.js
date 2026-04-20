// nwc-listener — POC: long-lived subscription for NWC notifications.
// This mirrors the pattern used by Alby Go (getAlby/go):
//   - NWCClient.subscribeNotifications() for long-lived WebSocket sub
//   - Handles encryption negotiation (NIP-04 vs NIP-44) automatically
//   - Auto-reconnects when the relay drops the connection
//
// Usage: node index.js "nostr+walletconnect://<pubkey>?relay=wss://...&secret=..."

import WebSocket from "ws";
import { useWebSocketImplementation } from "nostr-tools/pool";
import { NWCClient } from "@getalby/sdk/nwc";

// nostr-tools (used internally by the SDK) needs a WebSocket impl under Node.
useWebSocketImplementation(WebSocket);

const nwcUrl = process.argv[2];
if (!nwcUrl || !nwcUrl.startsWith("nostr+walletconnect://")) {
  console.error('Usage: node index.js "nostr+walletconnect://..."');
  process.exit(1);
}

const client = new NWCClient({ nostrWalletConnectUrl: nwcUrl });

console.log("--- NWC notification listener ---");
console.log("relay:     ", client.relayUrls[0]);
console.log("wallet pk: ", client.walletPubkey);
console.log("client pk: ", client.publicKey);
console.log("---------------------------------\n");

// Fetch wallet service info (also triggers encryption negotiation).
try {
  const info = await client.getWalletServiceInfo();
  console.log("encryptions: ", info.encryptions.join(", "));
  console.log("capabilities:", info.capabilities.join(", "));
  console.log("notifications:", info.notifications.join(", ") || "(none)");
  console.log();
} catch (err) {
  console.warn("Could not fetch wallet service info:", err.message);
  console.warn("(subscribeNotifications will still try to negotiate)\n");
}

// subscribeNotifications() opens a long-lived REQ on the relay for
// kind 23196 (NIP-04) or 23197 (NIP-44) depending on negotiated encryption.
// It auto-reconnects in a while loop when the relay closes the connection.
// This is the same pattern Alby Go uses in CreateInvoice.tsx.
console.log("Subscribing to notifications (long-lived REQ)...\n");

const unsub = await client.subscribeNotifications(
  (notification) => {
    const ts = new Date().toISOString();
    console.log(`=== ${ts} ===`);
    console.log("type:", notification.notification_type);
    console.log(JSON.stringify(notification.notification, null, 2));
    console.log();
  },
  // undefined = listen for all notification types
  // or pass e.g. ["payment_received", "payment_sent"]
  undefined,
);

// Keep the process alive; shut down cleanly on Ctrl+C.
process.on("SIGINT", () => {
  console.log("\nshutting down...");
  unsub();
  client.close();
  process.exit(0);
});
