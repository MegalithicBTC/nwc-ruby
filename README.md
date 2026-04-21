# nwc-ruby

A production-grade Ruby client for [Nostr Wallet Connect (NIP-47)][nip47].

Accept and track Bitcoin Lightning payments in your Rails app without running
any Lightning infrastructure yourself. Generate Lightning invoices for your
users to pay, then get notified the instant each one settles — all by talking
to a Nostr Wallet Connect (NWC) service that someone else operates. The gem
works with any NWC-compatible backend (Rizful, Alby Hub, Alby Cloud, CoinOs,
any NIP-47 wallet service), so you're not locked into a single provider and
can swap vendors by changing one environment variable.

```ruby
require "nwc_ruby"

client = NwcRuby::Client.from_uri(ENV["NWC_URL"])

# Create an invoice
invoice = client.make_invoice(amount: 1_000, description: "tip")
puts invoice["invoice"]

# Listen for payments, forever, reliably
client.subscribe_to_notifications do |n|
  puts "Got paid: #{n.amount_msats} msats for #{n.payment_hash}"
end
```

That's it. The gem handles the Nostr protocol, encryption, WebSocket lifecycle,
heartbeats, zombie-TCP detection, reconnects, and backoff. You call methods.

[nip47]: https://github.com/nostr-protocol/nips/blob/master/47.md

---

## Features

- **Full NIP-47 coverage** — `pay_invoice`, `multi_pay_invoice`, `pay_keysend`,
  `multi_pay_keysend`, `make_invoice`, `lookup_invoice`, `list_transactions`,
  `get_balance`, `get_info`, `sign_message`.
- **Notifications** — `payment_received` and `payment_sent` via kinds 23196
  (NIP-04) and 23197 (NIP-44 v2), deduplicated by `payment_hash`.
- **Both encryption schemes** — NIP-44 v2 when the wallet advertises it
  (validated against [paulmillr's test vectors][vectors]), NIP-04 fallback for
  wallets that haven't migrated.
- **Bulletproof long-running transport** — 15 s ping keepalive, 5-min forced
  recycle, capped exponential backoff, clean SIGTERM handling. Built on
  [async-websocket][aw] (no dead EventMachine dependency).
- **Two diagnostic methods** — `NwcRuby.test` (info, read tests, write test
  if applicable) and `NwcRuby.test_notifications` (listen forever in a separate
  process). Each tells you whether your NWC code works, exercises the methods
  the service advertises, and flags non-conforming responses with actionable
  errors. Callable from IRB, a Rails console, a spec, or a rake task.

[vectors]: https://github.com/paulmillr/nip44/blob/main/nip44.vectors.json
[aw]: https://github.com/socketry/async-websocket

---

## Get a free NWC connection string

You need a `nostr+walletconnect://...` URI. Two free, reliable options:

- **[rizful.com][rizful]** — Lightning vaults and cloud-based Lightning nodes designed for reliability and NWC support.
  built by the Megalith Node team. Dedicated NWC relay.
- **[getalby.com][alby]** — Alby Hub (self-hosted) or Alby Cloud. The
  most widely used NWC implementation.

[rizful]: https://rizful.com
[alby]: https://getalby.com

---

## Read-only vs read+write — understand this before you build

This is the single most important concept to internalize before using NWC. A
connection string's capabilities are set **when the wallet issues it** and
cannot be widened by the client.

### Read-only code

A read-only NWC code supports `get_info`, `get_balance`, `make_invoice`,
`lookup_invoice`, `list_transactions`, and typically notifications — but **not**
`pay_invoice` or `pay_keysend`. It cannot move funds out of the wallet.

**Use read-only for:** e-commerce checkouts (Shopify plugins, donation pages,
paywall integrations). Your server generates invoices, watches for
`payment_received` notifications, and credits the purchase. Even if your server
is fully compromised, the attacker cannot drain your wallet.

### Read+write code

A read+write code adds `pay_invoice`, `multi_pay_invoice`, `pay_keysend`, and
`multi_pay_keysend`. Anyone holding it can spend from your wallet up to the
budget / rate limits the wallet enforces.

**Use read+write for:** tipping bots, treasury automation, nostr zap clients,
any app that legitimately needs to send Lightning payments. **Treat the
connection string like a private key.** Don't commit it. Rotate it if leaked.
Use per-app codes with per-app budgets — never reuse your main wallet's code.

The gem tells you which mode you have:

```ruby
client = NwcRuby::Client.from_uri(ENV["NWC_URL"])
puts client.read_only?   # => true or false
puts client.capabilities # => ["get_info", "get_balance", "make_invoice", ...]
```

Or from IRB / a Rails console:

```ruby
NwcRuby.test_readonly(nwc_url: ENV["NWC_URL"])
# ...
# ℹ  This is a READ-ONLY code. It cannot move funds.
```

---

## Installation

Add to your Gemfile:

```ruby
gem "nwc-ruby"
```

Or install directly:

```sh
gem install nwc-ruby
```

The `rbsecp256k1` dependency is a C extension that bundles and compiles
`libsecp256k1` from source during `gem install`. You need a C toolchain and
a few libraries available **before** running `bundle install`.

**macOS:**

```sh
brew install automake openssl libtool pkg-config gmp libffi
```

**Ubuntu / Debian:**

```sh
sudo apt-get update
sudo apt-get install -y build-essential automake pkg-config libtool \
  libffi-dev libgmp-dev
```

**Alpine:**

```sh
apk add build-base automake autoconf libtool pkgconfig gmp-dev libffi-dev
```

**Docker (Kamal / production):**

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential automake pkg-config libtool libffi-dev libgmp-dev \
    && rm -rf /var/lib/apt/lists/*
```

If you see `LoadError: cannot load such file -- secp256k1` at runtime, the
native extension wasn't compiled. Install the build dependencies above and
run `gem pristine rbsecp256k1` (or re-run `bundle install`) to rebuild it.

---

## Usage

### One-shot requests

Each call transparently opens a WebSocket, sends the request, waits for the
response, and closes the connection.

```ruby
client = NwcRuby::Client.from_uri(ENV["NWC_URL"])

info = client.get_info
# => {"alias"=>"my-node", "color"=>"#3399FF", "pubkey"=>"...",
#     "network"=>"mainnet", "block_height"=>820_000, "block_hash"=>"...",
#     "methods"=>[...], "notifications"=>[...]}

balance = client.get_balance["balance"]  # msats

invoice = client.make_invoice(amount: 10_000, description: "coffee")
# => {"type"=>"incoming", "state"=>"pending",
#     "invoice"=>"lnbc100n1p...", "payment_hash"=>"...",
#     "amount"=>10_000, "created_at"=>1_730_000_000, ...}

status = client.lookup_invoice(payment_hash: invoice["payment_hash"])
# state: "pending" -> "settled"

# Only if read+write:
client.pay_invoice(invoice: "lnbc...")
# => {"preimage"=>"<64 hex chars>", "fees_paid"=>1234}
```

### Listening for notifications

This is the scenario the gem is most carefully engineered for: a long-running
process that needs to credit invoices the instant they're paid.

```ruby
client = NwcRuby::Client.from_uri(ENV["NWC_URL"])

client.subscribe_to_notifications do |notification|
  case notification.type
  when "payment_received"
    Invoice.find_by(payment_hash: notification.payment_hash)
           &.mark_paid!(amount_msats: notification.amount_msats)
  when "payment_sent"
    Payout.find_by(payment_hash: notification.payment_hash)&.mark_settled!
  end
end
# Blocks forever. SIGTERM / SIGINT cause a clean exit.
```

Under the hood, this subscribes to both kind 23196 (NIP-04) and kind 23197
(NIP-44 v2), dedupes by `payment_hash`, sends a WebSocket ping every 15 seconds
to keep middleboxes from idle-closing the socket, reconnects with capped
exponential backoff on failure, and force-recycles the connection every 5 minutes
as a belt-and-suspenders check against silently dead TCP streams.

#### Resuming after a restart

Persist the `created_at` of the last notification you processed and pass it as
`since:` on restart to avoid replaying history:

```ruby
since = AppState.get("nwc_last_seen") || Time.now.to_i

client.subscribe_to_notifications(since: since) do |n|
  process(n)
  AppState.set("nwc_last_seen", n.event.created_at)
end
```

### Using in a Rails app (Kamal deployment)

The Ruby NWC listener is best deployed as a [Kamal role][kamal-roles] — the
same app image as your web container, but with a different `cmd`. This is the
canonical 37signals pattern for a Sidekiq/Solid Queue/cron/listener process.
**Don't use a Kamal "accessory" for this** — accessories are for third-party
services (Postgres, Redis) and are not redeployed on `kamal deploy`.

```yaml
# config/deploy.yml
service: myapp
image: ghcr.io/myorg/myapp

servers:
  web:
    hosts: [10.0.0.10]
  nwc_listener:
    hosts: [10.0.0.10]
    cmd: "bundle exec rake nwc:listen_in_app"
    options:
      memory: 512m
```

**Important: make your notification handler idempotent.** During deploys,
reconnects, or if you scale `nwc_listener` to multiple hosts, the same
`payment_received` notification can be delivered more than once. The gem
deduplicates within a single process lifetime, but across restarts or multiple
instances you must handle duplicates at the database level. Use a unique
constraint on `payment_hash` (or an `UPDATE ... WHERE state != 'paid'` guard)
so that processing the same notification twice is a harmless no-op — never
double-credit a payment.

Define the listener rake task in your app. Use Postgres `LISTEN/NOTIFY` or
GoodJob to communicate with the web container:

```ruby
# lib/tasks/nwc.rake (in your Rails app)
namespace :nwc do
  task listen_in_app: :environment do
    client = NwcRuby::Client.from_uri(ENV["NWC_URL"])
    since  = AppState.find_or_create_by(key: "nwc_last_seen").value.to_i
    since  = Time.now.to_i if since.zero?

    client.subscribe_to_notifications(since: since) do |n|
      Invoice.transaction do
        # Idempotent: only transitions pending → paid, ignores already-paid rows.
        rows = Invoice.where(payment_hash: n.payment_hash, state: "pending")
                      .update_all(
                        state: "paid",
                        paid_amount_msats: n.amount_msats,
                        paid_at: Time.at(n.event.created_at)
                      )
        AppState.where(key: "nwc_last_seen").update_all(value: n.event.created_at)
        ActiveRecord::Base.connection.execute("NOTIFY nwc_invoice_paid") if rows > 0
      end
    end
  end
end
```

Docker's `--restart unless-stopped` (Kamal's default) plus the gem's internal
reconnect loop plus a SIGTERM trap gives you crash-only reliability without
systemd, foreman, or any process supervisor.

If you run the listener on multiple hosts, each instance receives the same
notifications independently. This is fine as long as the handler is idempotent
(as shown above). Running multiple instances gives you redundancy — if one
host goes down, the others keep listening — but they do not partition work.

[kamal-roles]: https://kamal-deploy.org/docs/configuration/roles/

---

## Testing against a real wallet

The gem ships two diagnostic methods. Call them from anywhere — IRB, a Rails
console, an RSpec test, or a rake task in your own app.

### `NwcRuby.test` — info, read tests, write test

Parses the connection string, fetches info, runs all read tests (`get_info`,
`get_balance`, `list_transactions`, `make_invoice`, `lookup_invoice`). If the
code is read+write **and** you provide a Lightning address, it also sends a
real payment via `pay_invoice`. If you provide a Lightning address but the code
is read-only, it prints a helpful warning instead of failing.

```ruby
NwcRuby.test(
  nwc_url:                  ENV["NWC_URL"],
  pay_to_lightning_address: "you@rizful.com", # optional — only used if code is read+write
  pay_to_satoshis_amount:   10                # default: 100
)
# => true if all checks passed, false otherwise
```

### `NwcRuby.test_notifications` — listen for notifications

Subscribes to notifications and **blocks forever**, printing each one as it
arrives. Run this in a **separate terminal / process**. Ctrl-C to stop.

```ruby
NwcRuby.test_notifications(nwc_url: ENV["NWC_URL"])
```

### Using `bin/nwc_test`

```sh
# Test (read tests + write test if applicable)
NWC_URL="..." PAY_TO_LIGHTNING_ADDRESS=you@example.com bin/nwc_test

# Listen for notifications (blocks forever — run in a separate terminal)
NWC_URL="..." bin/nwc_test notifications
```

### Calling from a Rails console

```sh
bin/rails c
```

```ruby
NwcRuby.test(nwc_url: ENV["NWC_URL"])
```

### Wrapping in your own rake tasks

```ruby
# lib/tasks/nwc.rake (in your Rails app)
namespace :nwc do
  desc "Run NWC diagnostic (read tests + write test if applicable)."
  task test: :environment do
    ok = NwcRuby.test(
      nwc_url:                  ENV.fetch("NWC_URL"),
      pay_to_lightning_address: ENV["PAY_TO_LIGHTNING_ADDRESS"],
      pay_to_satoshis_amount:   Integer(ENV.fetch("PAY_TO_SATOSHIS_AMOUNT", 100))
    )
    exit(ok ? 0 : 1)
  end

  desc "Listen for NWC notifications (blocks forever)."
  task notifications: :environment do
    NwcRuby.test_notifications(nwc_url: ENV.fetch("NWC_URL"))
  end
end
```

### Sample output (`NwcRuby.test`)

```
NWC Ruby diagnostic

  ✓ Connection string parsed
  ✓ Fetched info event (kind 13194)

  ⚠  This code is READ+WRITE and can allow payments. Be careful with it.

  Supported methods:
    ✓ pay_invoice       (mutating)
    ✓ multi_pay_invoice (mutating)
    — pay_keysend
    — multi_pay_keysend
    ✓ make_invoice
    ✓ lookup_invoice
    ✓ list_transactions
    ✓ get_balance
    ✓ get_info
    — sign_message

  Notifications: payment_received, payment_sent

  ✓ Encryption: nip44_v2, nip04 — will use NIP-44 v2

Read tests
  ✓ get_info (214ms)
  ✓ get_balance (188ms)
  ✓ list_transactions (312ms)
  ✓ make_invoice (1000 msats) (267ms)
  ✓ lookup_invoice (payment_hash from previous step) (241ms)

Write tests  (read+write code detected, Lightning address provided)
  ✓ pay_invoice (10 sats to you@rizful.com) (1843ms)

All tests passed.
```

### Sample output (`NwcRuby.test_notifications`)

```
NWC Ruby diagnostic

  ✓ Connection string parsed
  ✓ Fetched info event (kind 13194)

Listening for notifications...
Press Ctrl-C to stop.

  ✓ 2026-04-20 21:19:05 — payment_received
    payment_hash=58e45fee1b5ebe83807944896ff99e9252594ef3be4e3404c3ba2ab4536a9988
    amount=11000 msats
```

When the wallet service misbehaves, the runner flags it:

```
✗ make_invoice: `type` should be 'incoming'
✗ get_info: `network` is "unknown", expected one of mainnet/testnet/signet/regtest
✗ lookup_invoice: wallet returned INTERNAL:
  → The wallet service accepted the request but never responded.
```

---

## API reference

### `NwcRuby::Client`

Constructor:

| Method                          | Returns                                             |
| ------------------------------- | --------------------------------------------------- |
| `Client.from_uri(uri)`          | `Client` — parses the `nostr+walletconnect://` URI  |
| `Client.new(connection_string)` | `Client` — if you already have a `ConnectionString` |

Introspection:

| Method            | Returns                                  |
| ----------------- | ---------------------------------------- |
| `#info(refresh:)` | `NIP47::Info` — cached on first call     |
| `#capabilities`   | `Array<String>` — supported method names |
| `#read_only?`     | `Boolean`                                |
| `#read_write?`    | `Boolean`                                |

Methods (all raise `WalletServiceError` on wallet-side errors and
`TimeoutError` after 30 s of silence):

| Method               | Params                                                                 | Returns (hash keys)                                                                             |
| -------------------- | ---------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `#pay_invoice`       | `invoice:`, `amount:` (msats, optional partial)                        | `preimage`, `fees_paid`                                                                         |
| `#multi_pay_invoice` | `invoices: [{id:, invoice:, amount:}]`                                 | array of results                                                                                |
| `#pay_keysend`       | `amount:`, `pubkey:`, `preimage:`, `tlv_records:`                      | `preimage`, `fees_paid`                                                                         |
| `#multi_pay_keysend` | `keysends: [...]`                                                      | array of results                                                                                |
| `#make_invoice`      | `amount:`, `description:`, `description_hash:`, `expiry:`, `metadata:` | `type`, `state`, `invoice`, `payment_hash`, `amount`, `created_at`, `expires_at`                |
| `#lookup_invoice`    | `payment_hash:` or `invoice:`                                          | same as `make_invoice`, plus `settled_at`, `preimage`                                           |
| `#list_transactions` | `from:`, `until_ts:`, `limit:`, `offset:`, `unpaid:`, `type:`          | `transactions: [...]`                                                                           |
| `#get_balance`       | —                                                                      | `balance` (msats)                                                                               |
| `#get_info`          | —                                                                      | `alias`, `color`, `pubkey`, `network`, `block_height`, `block_hash`, `methods`, `notifications` |
| `#sign_message`      | `message:`                                                             | `message`, `signature`                                                                          |

Listener:

| Method                                          | Description                                   |
| ----------------------------------------------- | --------------------------------------------- |
| `#subscribe_to_notifications(since:) { \|n\| }` | Blocks forever. Yields `NIP47::Notification`. |

### `NwcRuby::NIP47::Notification`

| Field           |                                          |
| --------------- | ---------------------------------------- |
| `#type`         | `"payment_received"` or `"payment_sent"` |
| `#payment_hash` | hex                                      |
| `#amount_msats` | integer                                  |
| `#data`         | full notification hash                   |
| `#event`        | the underlying `Event`                   |

### Errors

All gem errors inherit from `NwcRuby::Error`:

- `InvalidConnectionStringError` — the URI couldn't be parsed.
- `EncryptionError` — bad MAC / bad padding / unknown version byte / bad key.
- `InvalidSignatureError` — an event's signature did not verify.
- `TransportError` — the WebSocket couldn't connect or died unrecoverably.
- `TimeoutError` — no response within the timeout window.
- `UnsupportedMethodError` — wallet service doesn't advertise this method.
- `WalletServiceError` — the wallet returned an error envelope. Check `#code`
  for `RATE_LIMITED`, `NOT_IMPLEMENTED`, `INSUFFICIENT_BALANCE`,
  `QUOTA_EXCEEDED`, `RESTRICTED`, `UNAUTHORIZED`, `INTERNAL`,
  `UNSUPPORTED_ENCRYPTION`, `PAYMENT_FAILED`, `NOT_FOUND`, or `OTHER`.

---

## Security notes

- **NIP-44 v2 correctness is a gated invariant.** The gem's test suite verifies
  against [paulmillr's canonical vectors][vectors]. Report any discrepancy as
  a security issue.
- **Never log the `secret` portion of a connection string.** It is a private
  key. The gem's logger never emits it.
- **Prefer read-only codes** for any server that doesn't strictly need to
  spend. The extra operational overhead of a read+write code (rotation, budget
  limits, audit logging) is usually not worth it for checkout flows.
- **MAC verification runs in constant time before decryption returns.** The
  `NIP44::Cipher.decrypt` path rejects unknown version bytes and fails closed
  on bad padding.

---

## Development

```sh
git clone https://github.com/MegalithicBTC/nwc-ruby
cd nwc-ruby
bundle install
bundle exec rspec
```

To run the diagnostics against a real wallet while developing the gem itself:

```sh
# Test (read + write if applicable)
bundle exec ruby -Ilib -rnwc_ruby -e '
  NwcRuby.test(
    nwc_url: ENV["NWC_URL"],
    pay_to_lightning_address: ENV["LN_ADDR"],
    pay_to_satoshis_amount: 10
  )
'

# Listen for notifications (separate terminal)
bundle exec ruby -Ilib -rnwc_ruby -e '
  NwcRuby.test_notifications(nwc_url: ENV["NWC_URL"])
'
```

Or drop into IRB:

```sh
bundle exec irb -Ilib -rnwc_ruby
> NwcRuby.test(nwc_url: ENV["NWC_URL"])
```

---

## Contributing

PRs welcome. Please include RSpec coverage. For crypto changes, include or
update the vectors in `spec/fixtures/`.

1. Fork it
2. Create your feature branch (`git checkout -b feature/my-change`)
3. Commit your changes
4. Push to the branch
5. Create a Pull Request

## License

MIT. See [LICENSE](LICENSE).

## Prior art and thanks

- [NIP-47 spec][nip47]
- [`@getalby/sdk`][alby-sdk] — the reference JavaScript implementation.
- [BLFS][blfs] — Bitcoin Lightning For Shopify

[alby-sdk]: https://github.com/getAlby/js-sdk/tree/master/src/nwc
[blfs]: https://docs.megalithic.me/BLFS/
