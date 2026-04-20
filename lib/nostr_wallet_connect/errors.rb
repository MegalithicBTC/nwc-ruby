# frozen_string_literal: true

module NostrWalletConnect
  # Base class for all gem errors. Rescue this to catch anything the gem raises.
  class Error < StandardError; end

  # The connection string is missing or malformed.
  class InvalidConnectionStringError < Error; end

  # Encryption / decryption failed (bad MAC, bad padding, unknown version byte).
  class EncryptionError < Error; end

  # Signature verification failed on an inbound event.
  class InvalidSignatureError < Error; end

  # The relay could not be reached, or the connection died and did not recover
  # within the configured timeout.
  class TransportError < Error; end

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
  end

  # A request was sent but no response arrived within the timeout window.
  class TimeoutError < Error; end

  # The wallet service does not support the method we tried to call. Check
  # `Client#capabilities` first, or use a read+write NWC string.
  class UnsupportedMethodError < Error; end
end
