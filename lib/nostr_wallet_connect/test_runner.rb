# frozen_string_literal: true

require 'net/http'
require 'uri'

module NostrWalletConnect
  # A diagnostic test runner for a live NWC connection string. Surfaces
  # misbehavior with actionable error messages rather than cryptic failures.
  #
  # Exposed both as a class and through the convenience method
  # `NostrWalletConnect.test(...)`. Call it from IRB, a Rails console, a
  # custom rake task in your own app, a spec — anywhere.
  #
  # Example:
  #
  #   NostrWalletConnect.test(
  #     nwc_url: "nostr+walletconnect://...",
  #     pay_to_lightning_address: "you@getalby.com",
  #     pay_to_satoshis_amount: 10
  #   )
  class TestRunner
    PASS = "\e[32m✓\e[0m"
    FAIL = "\e[31m✗\e[0m"
    WARN = "\e[33m!\e[0m"
    SKIP = "\e[90m—\e[0m"
    BOLD = "\e[1m"
    DIM  = "\e[90m"
    CLR  = "\e[0m"

    DEFAULT_SATOSHIS = 100

    # @param nwc_url [String] the nostr+walletconnect:// connection string
    # @param pay_to_lightning_address [String, nil] Lightning address to send
    #   the write test payment to. Only used if the NWC code is read+write.
    # @param pay_to_satoshis_amount [Integer] amount in sats used for both
    #   the outbound write test (if applicable) and the inbound make_invoice
    #   generated for the notification test. Defaults to 100.
    # @param output [IO] where to print diagnostic output.
    def initialize(nwc_url:,
                   pay_to_lightning_address: nil,
                   pay_to_satoshis_amount: DEFAULT_SATOSHIS,
                   output: $stdout)
      @nwc_url                  = nwc_url
      @pay_to_lightning_address = pay_to_lightning_address
      @pay_to_satoshis_amount   = Integer(pay_to_satoshis_amount)
      @out                      = output
      @failures                 = []
    end

    def run
      header
      return false unless validate_connection_string
      return false unless fetch_info

      announce_mode
      check_encryption_support

      run_read_tests
      run_write_tests if @info.read_write? && @pay_to_lightning_address
      run_inbound_payment_test

      summary
      @failures.empty?
    end

    private

    def header
      @out.puts "#{BOLD}Nostr Wallet Connect diagnostic#{CLR}"
      @out.puts "#{DIM}gem version #{NostrWalletConnect::VERSION}#{CLR}"
      @out.puts
    end

    def validate_connection_string
      if @nwc_url.to_s.empty?
        fail!('No NWC URL provided. Pass nwc_url: to TestRunner.new or NostrWalletConnect.test.')
        return false
      end
      @conn_str = ConnectionString.parse(@nwc_url)
      pass('Connection string parsed')
      @out.puts "  #{DIM}wallet_pubkey: #{@conn_str.wallet_pubkey}#{CLR}"
      @out.puts "  #{DIM}client_pubkey: #{@conn_str.client_pubkey}#{CLR}"
      @out.puts "  #{DIM}relay:         #{@conn_str.relays.first}#{CLR}"
      @out.puts
      true
    rescue InvalidConnectionStringError => e
      fail!("Invalid NWC URL: #{e.message}")
      false
    end

    def fetch_info
      @client = Client.from_uri(@nwc_url)
      @info   = @client.info
      pass('Fetched info event (kind 13194)')
      true
    rescue TransportError => e
      fail!("Could not fetch info event: #{e.message}")
      fail!('  → Confirm the relay URL is reachable and that the wallet service has published its kind 13194 event.')
      false
    rescue StandardError => e
      fail!("Unexpected error fetching info: #{e.class}: #{e.message}")
      false
    end

    def announce_mode
      @out.puts
      if @info.read_write?
        @out.puts "  #{BOLD}\e[33m⚠  This code is READ+WRITE and can allow payments. Be careful with it.#{CLR}"
      else
        @out.puts "  #{BOLD}\e[36mℹ  This is a READ-ONLY code. It cannot move funds.#{CLR}"
      end
      @out.puts
      @out.puts '  Supported methods:'
      NIP47::Methods::ALL.each do |method|
        marker = @info.supports?(method) ? PASS : SKIP
        mutates = NIP47::Methods::MUTATING.include?(method) ? "#{DIM}(mutating)#{CLR}" : ''
        @out.puts "    #{marker} #{method} #{mutates}"
      end
      @out.puts
      @out.puts "  Notifications: #{@info.notification_types.empty? ? '(none advertised)' : @info.notification_types.join(', ')}"
      @out.puts
    end

    def check_encryption_support
      schemes = @info.encryption_schemes.join(', ')
      if @info.supports_nip44?
        pass("Encryption: #{schemes} — will use NIP-44 v2")
      else
        warn!("Encryption: #{schemes} — wallet service does not advertise nip44_v2. Will fall back to NIP-04.")
        warn!('  → NIP-04 is deprecated. Consider a wallet service that supports NIP-44 v2.')
      end
      @out.puts
    end

    def run_read_tests
      @out.puts "#{BOLD}Read tests#{CLR}"

      try('get_info', NIP47::Methods::GET_INFO) do
        result = @client.get_info
        @get_info_result = result
        @out.puts "    #{DIM}alias=#{result['alias']} network=#{result['network']} pubkey=#{result['pubkey']}#{CLR}"
        @out.puts "    #{DIM}lud16=#{result['lud16']}#{CLR}" if result['lud16']
        sanity_check_get_info(result)
      end

      try('get_balance', NIP47::Methods::GET_BALANCE) do
        result = @client.get_balance
        @out.puts "    #{DIM}balance=#{result['balance']} msats#{CLR}"
        fail!('get_balance: `balance` field missing or not an integer') unless result['balance'].is_a?(Integer)
      end

      try('list_transactions', NIP47::Methods::LIST_TRANSACTIONS) do
        result = @client.list_transactions(limit: 5)
        txs = result['transactions'] || []
        @out.puts "    #{DIM}returned #{txs.size} transactions#{CLR}"
        unless result['transactions'].is_a?(Array)
          fail!('list_transactions: `transactions` field missing or not an array')
        end
      end

      try('make_invoice (1000 msats)', NIP47::Methods::MAKE_INVOICE) do
        result = @client.make_invoice(amount: 1_000, description: 'nostr_wallet_connect gem test')
        @out.puts "    #{DIM}invoice=#{truncate(result['invoice'], 40)}#{CLR}"
        @out.puts "    #{DIM}payment_hash=#{result['payment_hash']}#{CLR}"
        sanity_check_make_invoice(result)
        @test_payment_hash = result['payment_hash']
      end

      if @test_payment_hash
        try('lookup_invoice (payment_hash from previous step)', NIP47::Methods::LOOKUP_INVOICE) do
          result = @client.lookup_invoice(payment_hash: @test_payment_hash)
          @out.puts "    #{DIM}state=#{result['state']} amount=#{result['amount']} msats#{CLR}"
          fail!("lookup_invoice: `state` should be 'pending' for a fresh invoice") unless result['state'] == 'pending'
        end
      end

      @out.puts
    end

    def run_write_tests
      @out.puts "#{BOLD}Write tests#{CLR}  #{DIM}(read+write code detected, Lightning address provided)#{CLR}"

      amount_msats        = @pay_to_satoshis_amount * 1_000
      invoice_from_lnaddr = fetch_invoice_from_lightning_address(@pay_to_lightning_address, amount_msats)

      if invoice_from_lnaddr.nil?
        fail!("Could not resolve Lightning address #{@pay_to_lightning_address} — skipping pay_invoice test")
        @out.puts
        return
      end

      try("pay_invoice (#{@pay_to_satoshis_amount} sats to #{@pay_to_lightning_address})",
          NIP47::Methods::PAY_INVOICE) do
        result = @client.pay_invoice(invoice: invoice_from_lnaddr)
        @out.puts "    #{DIM}preimage=#{result['preimage']}#{CLR}"
        unless result['preimage'] && result['preimage'].match?(/\A[0-9a-f]{64}\z/)
          fail!("pay_invoice: `preimage` should be 64 hex chars, got #{result['preimage'].inspect}")
        end
      end
      @out.puts
    end

    def run_inbound_payment_test
      @out.puts "#{BOLD}Inbound payment test#{CLR}  #{DIM}(verifies the wallet delivers payment_received notifications)#{CLR}"

      unless @info.supports?(NIP47::Methods::MAKE_INVOICE)
        @out.puts "  #{SKIP} wallet service does not support make_invoice — cannot run inbound test"
        @out.puts
        return
      end

      unless @info.supports_notifications?
        warn!('wallet service does not advertise notifications in its info event')
        warn!("  → We'll still print an invoice so you can test manually, but we cannot verify receipt via notifications.")
      end

      amount_msats = @pay_to_satoshis_amount * 1_000
      invoice_result =
        begin
          @client.make_invoice(amount: amount_msats, description: 'nostr_wallet_connect gem inbound test')
        rescue WalletServiceError => e
          fail!("make_invoice failed: #{e.code}: #{e.message} — cannot run inbound test")
          @out.puts
          return
        rescue StandardError => e
          fail!("make_invoice failed: #{e.class}: #{e.message} — cannot run inbound test")
          @out.puts
          return
        end

      invoice      = invoice_result['invoice']
      payment_hash = invoice_result['payment_hash']
      lud16        = @get_info_result && @get_info_result['lud16']

      @out.puts
      @out.puts "  #{BOLD}\e[36mPlease send a payment to exercise inbound notifications.#{CLR}"
      @out.puts
      if lud16
        @out.puts "  #{BOLD}Option A — Lightning address (any amount works):#{CLR}"
        @out.puts "    #{BOLD}#{lud16}#{CLR}"
        @out.puts
        @out.puts "  #{BOLD}Option B — BOLT11 invoice (#{@pay_to_satoshis_amount} sats, payment_hash will be matched):#{CLR}"
      else
        @out.puts "  #{BOLD}Pay this BOLT11 invoice (#{@pay_to_satoshis_amount} sats):#{CLR}"
      end
      @out.puts "    #{invoice}"
      @out.puts
      @out.puts "  #{DIM}Waiting up to 180 seconds for a payment_received notification...#{CLR}"
      @out.puts "  #{DIM}Press Ctrl-C to stop waiting early.#{CLR}"
      @out.puts

      timeout  = 180
      deadline = Time.now + timeout
      received = []

      # Run the subscription on a background thread so the main thread can
      # tick down the deadline and respond to Ctrl-C.
      sub_thread = Thread.new do
        Thread.current.report_on_exception = false
        begin
          @client.subscribe_to_notifications(since: Time.now.to_i - 2) do |n|
            received << n if n.type == 'payment_received'
          end
        rescue TransportError
          # Connection died; main loop will notice and report.
        end
      end

      last_tick = nil
      begin
        while Time.now < deadline
          break if received.any? { |n| n.payment_hash == payment_hash }

          sleep 0.5
          remaining = (deadline - Time.now).to_i
          if remaining > 0 && remaining % 30 == 0 && remaining != last_tick
            @out.puts "  #{DIM}... still waiting (#{remaining}s remaining)#{CLR}"
            last_tick = remaining
          end
        end
      rescue Interrupt
        @out.puts
        @out.puts "  #{DIM}Interrupted by user.#{CLR}"
      end

      sub_thread.kill if sub_thread.alive?

      matched = received.find { |n| n.payment_hash == payment_hash }

      if matched
        pass('Received payment_received notification matching our invoice.')
        @out.puts "    #{DIM}payment_hash=#{matched.payment_hash}#{CLR}"
        @out.puts "    #{DIM}amount=#{matched.amount_msats} msats#{CLR}"
      elsif received.any?
        pass("Received #{received.size} payment_received notification(s), but none matched our invoice's payment_hash.")
        @out.puts "    #{DIM}(payments must have been sent to a different invoice, e.g. the lud16 address)#{CLR}"
        received.each do |n|
          @out.puts "    #{DIM}- payment_hash=#{n.payment_hash} amount=#{n.amount_msats} msats#{CLR}"
        end
        warn!('Inbound notifications are working for some invoices, but we never saw the specific one we generated.')
        warn!('  → If you paid the BOLT11 above, the wallet service may have a notification delivery gap.')
      else
        warn!("No payment_received notifications arrived within #{timeout}s.")
        warn!('  → Either no payment was sent, or the wallet service is not emitting notifications as it should.')
      end
      @out.puts
    end

    # --- Sanity checks ------------------------------------------------------

    def sanity_check_get_info(result)
      %w[alias pubkey network].each do |field|
        fail!("get_info: `#{field}` field is missing") if result[field].nil?
      end
      return if %w[mainnet testnet signet regtest].include?(result['network'])

      warn!("get_info: `network` is #{result['network'].inspect}, expected one of mainnet/testnet/signet/regtest")
    end

    def sanity_check_make_invoice(result)
      fail!('make_invoice: `invoice` is missing or not a BOLT11 string') unless result['invoice'].to_s.start_with?('ln')
      unless result['payment_hash'].to_s.match?(/\A[0-9a-f]{64}\z/)
        fail!('make_invoice: `payment_hash` is not a 64-char hex')
      end
      fail!('make_invoice: `amount` should echo 1000') unless result['amount'] == 1_000
      fail!("make_invoice: `type` should be 'incoming'") unless result['type'] == 'incoming'
      fail!("make_invoice: `state` should be 'pending'") unless result['state'] == 'pending'
    end

    # --- Lightning address resolver ----------------------------------------

    def fetch_invoice_from_lightning_address(address, amount_msats)
      user, domain = address.split('@', 2)
      return nil unless user && domain

      lnurlp = URI.parse("https://#{domain}/.well-known/lnurlp/#{user}")
      metadata = Net::HTTP.get_response(lnurlp)
      return nil unless metadata.is_a?(Net::HTTPSuccess)

      meta_json = JSON.parse(metadata.body)
      callback  = URI.parse(meta_json['callback'])
      callback.query = URI.encode_www_form(amount: amount_msats)
      resp = Net::HTTP.get_response(callback)
      return nil unless resp.is_a?(Net::HTTPSuccess)

      JSON.parse(resp.body)['pr']
    rescue StandardError => e
      @out.puts "  #{WARN} LNURL-pay resolution failed: #{e.class}: #{e.message}"
      nil
    end

    # --- Output helpers -----------------------------------------------------

    def try(label, method_name)
      unless @info.supports?(method_name)
        @out.puts "  #{SKIP} #{label}  #{DIM}(wallet service does not support this)#{CLR}"
        return
      end

      start = Time.now
      begin
        yield
        elapsed = ((Time.now - start) * 1000).round
        @out.puts "  #{PASS} #{label}  #{DIM}(#{elapsed}ms)#{CLR}"
      rescue WalletServiceError => e
        fail!("#{label}: wallet returned #{e.code}: #{e.message}")
      rescue TimeoutError => e
        fail!("#{label}: #{e.message}")
        fail!('  → The wallet service accepted the request but never responded. The service may be down or overloaded.')
      rescue UnsupportedMethodError => e
        fail!("#{label}: #{e.message}")
      rescue EncryptionError => e
        fail!("#{label}: decryption failed — #{e.message}")
        fail!('  → This usually means the wallet service encrypted with an unexpected scheme, or the shared secret is wrong.')
      rescue StandardError => e
        fail!("#{label}: unexpected error #{e.class}: #{e.message}")
      end
    end

    def pass(msg) = @out.puts("  #{PASS} #{msg}")
    def warn!(msg) = @out.puts("  #{WARN} #{msg}")

    def fail!(msg)
      @out.puts "  #{FAIL} #{msg}"
      @failures << msg
    end

    def truncate(str, n)
      s = str.to_s
      s.length > n ? "#{s[0, n]}..." : s
    end

    def summary
      @out.puts
      if @failures.empty?
        @out.puts "#{BOLD}\e[32mAll tests passed.#{CLR}"
      else
        @out.puts "#{BOLD}\e[31m#{@failures.size} failure(s).#{CLR}"
      end
    end
  end
end
