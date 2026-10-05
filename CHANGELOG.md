# Changelog

All notable changes to this gem will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] — 2026-10-05

### Changed

- **Failures now say whether the request reached the wallet.** Anything that
  fails before the request EVENT is written to the relay — DNS, TCP connect,
  TLS, the websocket upgrade, the info fetch — raises the new
  `NwcRuby::NotSentError` (a `TransportError` subclass, so existing rescues
  still match), with the original exception as `#cause` and only the relay
  host in the message. Failures after the write stay ambiguous:
  `TransportError` or `TimeoutError`. Previously a DNS failure surfaced as a
  raw `Socket::ResolutionError`, so callers could not tell "never sent, safe
  to retry" from "maybe paid".
- Public `Client` methods no longer leak raw `SocketError` / `Errno::*` /
  `OpenSSL::SSL::SSLError` / `Async::TimeoutError` / `Protocol::WebSocket`
  exceptions; everything is an `NwcRuby::Error`.
- A relay closing the connection after the request was sent now raises
  `TransportError` instead of a misleading `TimeoutError`.
- A relay answering the request with `["OK", id, false, reason]` now raises
  `TransportError` immediately instead of waiting out `request_timeout`. It is
  still treated as maybe-sent, since the relay is untrusted.
- "No info event" is now `InfoUnavailableError` (a `NotSentError`) instead of a
  plain `TransportError`.
- `request_timeout` now bounds the whole call, including connecting and the
  info fetch. Before, a relay that went silent could block a request
  indefinitely because the deadline was only checked when a message arrived.
- Errors are classified inside the Async task, so Async no longer logs
  "Task may have ended with unhandled exception" for request failures.

### Added

- `connect_retries:` (default 2): pre-send failures are retried with 0.25 s /
  1 s backoff inside `request_timeout`. Nothing is retried after the request is
  written.
- Requests and info fetches fall through to the next `relay` in the connection
  string on a pre-send failure (previously only the first relay was used).
- `NwcRuby::Error#sent?` — `false` for `NotSentError` and
  `UnsupportedMethodError`, `true` for `TransportError`, `TimeoutError` and
  `WalletServiceError`, `nil` where it doesn't apply.

## [0.2.4] — 2026-07-17

### Security

- **Event ids are now recomputed before the signature is trusted.**
  `Event#valid_signature?` verified the signature against the `id` supplied by
  the relay without checking that the `id` actually described the event body.
  Because a Nostr signature only ever commits to the `id`, nothing bound that
  `id` to the event it arrived with: a relay could lift a genuine
  `(id, sig, pubkey)` triple from any real wallet event and re-attach it to
  arbitrary `content`, `tags`, `kind` or `created_at`, and the result verified.
  The id is now recomputed from the canonical serialization first, via the new
  `Event#valid_id?`. Reported by @riccardobl in
  [#1](https://github.com/MegalithicBTC/nwc-ruby/issues/1).

  The sharpest edge was the kind 13194 info event, whose content and tags are
  plaintext: stripping its `encryption` tag silently downgraded every
  subsequent request from NIP-44 v2 to NIP-04, since the spec reads an absent
  tag as "nip04 only".

- **Responses are now bound to the request that asked for them.** `call` trusted
  the relay to honour the `#e` REQ filter and never checked the response's `e`
  tag itself, so a relay could replay an older but genuine response — a past
  "payment succeeded" answering a fresh `pay_invoice`, for instance.

- **`fetch_info` now verifies the event author.** It previously checked only
  `valid_signature?` and never compared the pubkey to the wallet's, so a relay
  could sign an info event with its own key and have it accepted — forcing the
  encryption downgrade above without needing to tamper with anything.

### Fixed

- The notification listener no longer tears down when a relay delivers an event
  of an unexpected kind. `Notification.parse` raises `ArgumentError` on a
  non-notification kind, but only `EncryptionError` was rescued, so a relay
  echoing a kind 23195 response onto the subscription killed the listener.
- A rejected info event no longer ends the `fetch_info` read loop, so one junk
  event cannot deny service while a genuine info event is still inbound.
- Corrected `source_code_uri` and `changelog_uri` in the gemspec, which pointed
  at a `main` branch that does not exist — both links 404'd from the RubyGems
  page. This repo uses `master`; `PUBLISHING.md` has been corrected to match.
- `PUBLISHING.md` no longer claims releases publish automatically on tag. There
  is no `release.yml` in this repo — only `ci.yml`, which tests but never
  publishes — so releases are manual.

### Added

- Documented a gentle `lookup_invoice` backup polling cadence for invoices so
  apps can recover from missed notifications without getting rate limited by the
  backing NWC service.

## [0.2.3] — 2026-04-23

### Fixed

- Silenced the noisy `Async::Task` warn log ("Task may have ended with
  unhandled exception") that was emitted every `recycle_interval` (default
  5 min) by the heartbeat task. The forced recycle used to be signaled by
  raising `TransportError` from inside the heartbeat's child Async task; the
  parent's reconnect loop caught it correctly, but Async's console logger
  logged the unhandled-in-child exception with a full backtrace first.
  The recycle is now signaled by setting an `@recycle_requested` flag and
  closing the websocket, which unblocks the read loop and lets
  `run_one_connection` return normally without any exception crossing a task
  boundary.

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
