# frozen_string_literal: true

module NwcRuby
  module NIP47
    # NIP-47 kinds and methods.
    module Methods
      # Event kinds.
      KIND_INFO                 = 13_194 # replaceable, plaintext capability list
      KIND_REQUEST              = 23_194 # client -> wallet, encrypted
      KIND_RESPONSE             = 23_195 # wallet -> client, encrypted
      KIND_NOTIFICATION_NIP04   = 23_196 # wallet -> client, NIP-04 encrypted
      KIND_NOTIFICATION_NIP44   = 23_197 # wallet -> client, NIP-44 v2 encrypted

      # Methods (the payload `method` field). The info event advertises a
      # space-separated subset of these.
      PAY_INVOICE         = 'pay_invoice'
      MULTI_PAY_INVOICE   = 'multi_pay_invoice'
      PAY_KEYSEND         = 'pay_keysend'
      MULTI_PAY_KEYSEND   = 'multi_pay_keysend'
      MAKE_INVOICE        = 'make_invoice'
      LOOKUP_INVOICE      = 'lookup_invoice'
      LIST_TRANSACTIONS   = 'list_transactions'
      GET_BALANCE         = 'get_balance'
      GET_INFO            = 'get_info'
      SIGN_MESSAGE        = 'sign_message'
      NOTIFICATIONS       = 'notifications' # capability marker, not a method

      ALL = [
        PAY_INVOICE, MULTI_PAY_INVOICE, PAY_KEYSEND, MULTI_PAY_KEYSEND,
        MAKE_INVOICE, LOOKUP_INVOICE, LIST_TRANSACTIONS,
        GET_BALANCE, GET_INFO, SIGN_MESSAGE
      ].freeze

      # The set of methods that can move funds. A connection without any of
      # these is "read-only".
      MUTATING = [
        PAY_INVOICE, MULTI_PAY_INVOICE, PAY_KEYSEND, MULTI_PAY_KEYSEND
      ].freeze

      NOTIFICATION_TYPES = %w[payment_received payment_sent].freeze
    end
  end
end
