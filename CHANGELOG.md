# Changelog

All notable changes to this gem will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] — 2026-04-20

### Fixed

- `subscribe_to_notifications` crashed on startup — `RelayConnection#initialize` was missing
  the `poll_interval:` keyword argument passed by the client.
- Ctrl+C / SIGINT / SIGTERM now exits cleanly — signal trap closes the WebSocket to unblock
  the read loop instead of only setting a flag.

### Changed

- `poll_interval` default changed from `5` to `nil` (disabled). The relay pushes events to
  active subscriptions, so periodic re-subscribe polling is unnecessary. Pass
  `poll_interval: 5` explicitly if your relay requires it.

## [0.1.0] — 2026-04-20

### Added

- Initial release.
- NIP-01 event construction, serialization, SHA-256 id, BIP-340 Schnorr signing & verification.
- NIP-04 (AES-256-CBC) encryption, for wallets that still only support legacy DMs.
- NIP-44 v2 encryption (ChaCha20 + HMAC-SHA256 + power-of-two padding), validated against
  [paulmillr/nip44](https://github.com/paulmillr/nip44/blob/main/nip44.vectors.json).
- NIP-47 `nostr+walletconnect://` URI parser.
- Full NIP-47 method coverage: `pay_invoice`, `multi_pay_invoice`, `pay_keysend`,
  `multi_pay_keysend`, `make_invoice`, `lookup_invoice`, `list_transactions`,
  `get_balance`, `get_info`, `sign_message`.
- Notification listener (kinds 23196 and 23197) with dedupe by `payment_hash`.
- Reliable long-running `Transport::RelayConnection`: RFC 6455 ping (30 s),
  pong deadline (45 s), forced recycle (5 min), capped exponential backoff,
  SIGTERM/SIGINT handling.
- `NwcRuby.test(nwc_url:, pay_to_lightning_address:, pay_to_satoshis_amount:)`
  diagnostic method, backed by `NwcRuby::TestRunner`. Announces
  read-only vs read+write, exercises every advertised method, pays a Lightning
  address if the code is read+write, generates an invoice and verifies the
  `payment_received` notification arrives. Callable from IRB, Rails console,
  RSpec, or a rake task in the host app.
