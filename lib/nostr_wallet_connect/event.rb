# frozen_string_literal: true

module NostrWalletConnect
  # A Nostr event (NIP-01).
  #
  # The canonical serialization for ID computation is a JSON array with no
  # whitespace between elements:
  #   [0, pubkey, created_at, kind, tags, content]
  # SHA-256 of that JSON is the event id; the event id is signed with BIP-340
  # Schnorr against the author's private key.
  class Event
    attr_accessor :id, :pubkey, :created_at, :kind, :tags, :content, :sig

    def initialize(pubkey:, kind:, content:, tags: [], created_at: Time.now.to_i)
      @pubkey     = pubkey
      @kind       = kind
      @content    = content
      @tags       = tags
      @created_at = created_at
    end

    # Build from a hash as received from the relay.
    def self.from_hash(h)
      e = allocate
      e.id         = h["id"]
      e.pubkey     = h["pubkey"]
      e.created_at = h["created_at"]
      e.kind       = h["kind"]
      e.tags       = h["tags"] || []
      e.content    = h["content"] || ""
      e.sig        = h["sig"]
      e
    end

    # JSON used for ID computation. MUST NOT contain whitespace between tokens
    # and MUST use the array form below.
    def serialize_for_id
      JSON.generate([0, @pubkey, @created_at, @kind, @tags, @content])
    end

    def compute_id!
      @id = OpenSSL::Digest::SHA256.hexdigest(serialize_for_id)
      self
    end

    def sign!(privkey_hex)
      compute_id!
      digest_bytes = Crypto::Keys.hex_to_bytes(@id)
      @sig = Crypto::Schnorr.sign(digest_bytes, privkey_hex)
      self
    end

    def valid_signature?
      return false unless @id && @sig && @pubkey

      digest_bytes = Crypto::Keys.hex_to_bytes(@id)
      Crypto::Schnorr.verify(digest_bytes, @sig, @pubkey)
    end

    def to_h
      {
        "id" => @id,
        "pubkey" => @pubkey,
        "created_at" => @created_at,
        "kind" => @kind,
        "tags" => @tags,
        "content" => @content,
        "sig" => @sig
      }
    end
  end
end
