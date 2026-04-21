# Changelog

All notable changes to this gem will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.2] — 2026-04-21

### Fixed

- Ctrl+C / SIGINT / SIGTERM now reliably exits the notification listener. The
  previous trap handler called `@conn.close` directly, which deadlocks because
  closing an SSL socket from inside a Ruby signal handler is unsafe
  (`docker stop` was the only way out).
- Replaced the trap-based close with a self-pipe: the trap only flips `@stop`
  and writes one byte to a pipe; an `Async` task reads from the pipe inside the
  reactor and calls `top.stop` from the correct fiber context. This avoids two
  further async-specific pitfalls discovered along the way — `Async::Task#stop`
  raises `ThreadError: can't be called from trap context` (uses a Mutex), and
  offloading to `Thread.new { task.stop }` fails with `NoMethodError` on
  `Fiber.scheduler` because the reactor lives on a different thread.
- Added `rescue Interrupt, Async::Stop` at the top of the reconnect-loop rescue
  chain in `RelayConnection#run!` so the stop signal is not swallowed by the
  generic reconnect-on-error path.

## [0.2.1] — 2026-04-20

### Fixed

- Fixed all RuboCop offenses (CI now passes clean).
- Extracted `start_heartbeat` / `start_poll` from `run_one_connection` to reduce
  method length and perceived complexity.
- Corrected README and CHANGELOG: transport uses 15 s ping keepalive (not 30 s
  ping + 45 s pong deadline — the pong deadline was removed in 0.1.1 due to
  async-websocket 0.30 API changes).
- Fixed string quoting, hash alignment, guard clause, and line length offenses
  across Rakefile, `bin/nwc_test`, `client.rb`, `test_runner.rb`, and
  `relay_connection.rb`.
- Excluded `lib/nwc-ruby.rb` from `Naming/FileName` (compatibility shim).

## [0.2.0] — 2026-04-20

### Changed

- **Breaking:** Split `NwcRuby.test` into two methods: `NwcRuby.test` (info +
  read tests + write test if applicable) and `NwcRuby.test_notifications`
  (subscribe and block forever, printing each notification). Notifications are
  now tested in a separate process instead of a background thread, which
  fixes the issue where notifications were never received during the
  integrated test.
- Removed `test_send_and_receive` and `test_readonly` — a single `test` method
  handles both read-only and read+write codes. If the code is read-only but
  a Lightning address is provided, it prints a helpful warning instead of failing.
- `bin/nwc_test` now accepts an optional `notifications` subcommand:
  `bin/nwc_test` (default test), `bin/nwc_test notifications` (listen forever).

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
- Reliable long-running `Transport::RelayConnection`: RFC 6455 ping (15 s),
  forced recycle (5 min), capped exponential backoff, SIGTERM/SIGINT handling.
- `NwcRuby.test` and `NwcRuby.test_notifications` diagnostic methods, backed
  by `NwcRuby::TestRunner`. Announces read-only vs read+write, exercises every
  advertised method, pays a Lightning address if the code is read+write.
  Callable from IRB, Rails console, RSpec, or a rake task in the host app.
