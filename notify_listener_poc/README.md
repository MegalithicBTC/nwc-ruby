# Notification Listener Proof of Concept

Listening to NWC notifications is a long-running task that can be tricky to get right — keeping the WebSocket alive, handling reconnects, negotiating encryption, etc. This proof of concept shows it working well in Node.js with the [Alby SDK](https://github.com/getAlby/js-sdk), which mirrors the pattern used by [Alby Go](https://github.com/getAlby/go).

## Usage

```bash
npm install
node index.js "nostr+walletconnect://<pubkey>?relay=wss://...&secret=..."
```

The script subscribes to `payment_received` and `payment_sent` notifications over a long-lived WebSocket and prints each one as it arrives. Press Ctrl-C to stop.
