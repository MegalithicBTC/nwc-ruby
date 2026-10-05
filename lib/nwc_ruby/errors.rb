# frozen_string_literal: true

module NwcRuby
  # Base class for all gem errors. Rescue this to catch anything the gem raises.
  class Error < StandardError
    # Whether the request reached the relay. Only `false` is a safe-to-retry
    # signal; `true` and `nil` mean the wallet may have acted on it.
    def sent? = nil # rubocop:disable Style/ReturnNilInPredicateMethodDefinition
  end

  # The connection string is missing or malformed.
  class InvalidConnectionStringError < Error; end

  # Encryption / decryption failed (bad MAC, bad padding, unknown version byte).
  class EncryptionError < Error; end

  # Signature verification failed on an inbound event.
  class InvalidSignatureError < Error; end

  # The connection to the relay failed after the request was written to it.
  # The wallet may have acted on the request, so do not blindly retry
  # payments; reconcile with `lookup_invoice` / `list_transactions` instead.
  # (`NotSentError` below is the safe-to-retry subclass.)
  class TransportError < Error
    def sent? = true
  end

  # The request never left this process: DNS, TCP connect, TLS, the websocket
  # upgrade, or the info fetch failed first. Always safe to retry. `#cause`
  # holds the original low-level exception.
  class NotSentError < TransportError
    def sent? = false
  end

  # The relay answered but holds no kind 13194 info event for this wallet.
  # Usually a wrong relay or wallet pubkey rather than a transient fault.
  class InfoUnavailableError < NotSentError; end

  # The wallet service returned an error envelope. `#code` is the NIP-47 error
  # code (one of RATE_LIMITED, NOT_IMPLEMENTED, INSUFFICIENT_BALANCE,
  # QUOTA_EXCEEDED, RESTRICTED, UNAUTHORIZED, INTERNAL, UNSUPPORTED_ENCRYPTION,
  # PAYMENT_FAILED, NOT_FOUND, or OTHER).
  class WalletServiceError < Error
    attr_reader :code

    def initialize(code, message)
      @code = code
      super("#{code}: #{message}")
    end

    def sent? = true
  end

  # A request was sent but no response arrived within the timeout window. The
  # wallet may have acted on it.
  class TimeoutError < Error
    def sent? = true
  end

  # The wallet service does not support the method we tried to call. Check
  # `Client#capabilities` first, or use a read+write NWC string. A
  # configuration problem: retrying will not help.
  class UnsupportedMethodError < Error
    def sent? = false
  end
end
