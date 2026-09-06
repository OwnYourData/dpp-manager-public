require "cgi"
require "timeout"

module Did
  # Everything this application does with did:oyd, behind one seam so the tests
  # can stub it and need neither the network nor a VDR.
  #
  # Minting happens HERE, on the operator's own machine, and that is the reason
  # the whole application is written in Ruby. The registrar's REST API would do
  # the same job, but it would carry `documentKey` and `revocationKey` back over
  # the wire — and those two are what makes the identity the operator's rather
  # than the service's.
  module Oyd
    class Error < StandardError; end

    DEFAULT_LOCATION = "https://oydid.ownyourdata.eu".freeze

    # oydid defaults to no key type at all, so this is mandatory: without it
    # Oydid.create raises NoMethodError (nil + "-priv") inside generate_base.
    KEY_TYPE = "ed25519".freeze

    RESOLVE_TIMEOUT = ENV.fetch("DID_RESOLVE_TIMEOUT", 15).to_i

    # The service type the DPP Service looks for when it checks that a DID handed
    # to it really is a passport DID. Copied from its own DidOyd, and a passport
    # minted with anything else is refused on submission.
    SERVICE_TYPE = "DigitalProductPassport".freeze

    module_function

    def location
      ENV.fetch("OYDID_LOCATION", DEFAULT_LOCATION)
    end

    # For the default repository oydid appends "@https://oydid.ownyourdata.eu"
    # to the identifier. The DPP Service normalises its own identifiers but
    # resolves a token's `iss` exactly as written, so the suffix has to go
    # before the DID is ever put in a token. For a non-default repository the
    # location is needed for resolution and is kept.
    def normalize(did)
      return did.to_s unless location == DEFAULT_LOCATION

      did.to_s.sub(
        /@(#{Regexp.escape(DEFAULT_LOCATION)}|#{Regexp.escape(CGI.escape(DEFAULT_LOCATION))})\z/, ""
      )
    end

    # Mint the operator's identity DID. It carries no service entry: it names an
    # actor, not a passport, and an actor has nothing to point at.
    #
    # Returns { did:, document_key:, revocation_key:, revocation_log: }. The two
    # keys exist in this return value and nowhere else — the registrar does not
    # keep them and cannot hand them out again.
    def mint(content = {})
      create(content, authentication: true)
    end

    # The passport's DID.
    #
    # Three differences from the identity's, and all three are the service's
    # rules rather than ours:
    #
    #   * it carries a service entry of type DigitalProductPassport, pointing at
    #     where the passport can be read. The service resolves the DID on
    #     submission and refuses one without it.
    #   * the endpoint's HOST is compared with where the passport is submitted.
    #     Only the host — the path may differ — but a DID minted against the
    #     service and then submitted to a custodian is refused, and the only
    #     remedy is a new identifier. Hence endpoint_base is an argument here and
    #     a stored column there: this decision has to be made before minting and
    #     visible afterwards.
    #   * no `authentication`. A passport DID authenticates nothing; it names a
    #     thing, not an actor. The identity signs on its behalf.
    #
    # The endpoint is built exactly as the DPP Service builds it, escaping
    # included, so that a passport minted here is indistinguishable from one the
    # service minted for itself.
    def mint_passport(product_id, endpoint_base:)
      raise Error, "the passport has no product identifier yet" if product_id.to_s.strip.empty?
      raise Error, "there is no endpoint to point the passport at" if endpoint_base.to_s.strip.empty?

      content = { "service" => [ { "type"            => SERVICE_TYPE,
                                   "serviceEndpoint" => service_endpoint(product_id, endpoint_base) } ] }

      create(content, authentication: false)
    end

    # Point an existing passport DID at a different host.
    #
    # What makes a handover possible at all. The DID's serviceEndpoint says
    # where the passport can be read; moving the passport to another custodian
    # without moving the endpoint would leave the world reading whatever the
    # old host still serves.
    #
    # An update mints a new identifier — did:oyd names a document by its hash,
    # so a changed document is a changed name — but the ORIGINAL identifier goes
    # on resolving to the current document, because resolution walks the log.
    # That is the property everything here rests on: the identifier printed on
    # the product does not change, ever. Verified against the registry rather
    # than assumed.
    #
    # The keys stay the same: they are passed as both the old and the new key
    # material, so the operator keeps the two secrets they wrote down. What does
    # change is the revocation log — it commits to the current document — so the
    # caller has to store the one that comes back or lose the ability to revoke.
    #
    # `authentication: false` is repeated here deliberately. oydid rebuilds the
    # document from the content on every write and drops the section silently if
    # the option is left out; a passport DID must not gain an authentication
    # method by being moved.
    def move_endpoint(did, product_id:, endpoint_base:, document_key:, revocation_key:)
      require "oydid"

      raise Error, "there is no endpoint to point the passport at" if endpoint_base.to_s.strip.empty?

      content = { "service" => [ { "type"            => SERVICE_TYPE,
                                   "serviceEndpoint" => service_endpoint(product_id, endpoint_base) } ] }

      result, message = ::Oydid.update(content, did.to_s, {
        return_secrets: true, key_type: KEY_TYPE, authentication: false,
        doc_enc: document_key, old_doc_enc: document_key,
        rev_enc: revocation_key, old_rev_enc: revocation_key,
        location: location, doc_location: location
      })
      raise Error, (message.presence || "Oydid.update returned no result") if result.nil?

      { did: normalize(result["did"]), revocation_log: result["revocation_log"].to_json }
    end

    def service_endpoint(product_id, endpoint_base)
      "#{endpoint_base.to_s.strip.chomp('/')}/dpp/v1/dppsByProductId/#{CGI.escape(product_id.to_s)}"
    end

    def create(content, authentication:)
      require "oydid"

      # :location goes into the identifier itself (the "@<repo>" suffix that
      # normalize strips again for the default repository), :doc_location is the
      # repository the document and log are published to. Two separate options:
      # passing only :doc_location silently mints a DID without its location
      # suffix.
      #
      # :authentication writes `authentication: ["#key-doc"]` into the document,
      # which is what DID Core wants of an identifier whose only purpose is
      # authenticating to a service. It is not cosmetic: the section sits inside
      # the hashed payload, so it changes the identifier and the log hash. Two
      # consequences worth knowing before touching this line.
      #
      # It cannot be added afterwards. A DID minted without it can only gain it
      # through an update, and that mints a new identifier — so this has to be
      # right the first time, for every identity, or not at all.
      #
      # And it has to be repeated on every update. oydid rebuilds the document
      # from the content each time; leaving the option out drops the section
      # silently, with no error and no warning. There is no update path here yet.
      # Whoever writes one has to pass this too.
      result, message = ::Oydid.create(content, { return_secrets: true,
                                                  key_type:       KEY_TYPE,
                                                  authentication: authentication,
                                                  location:       location,
                                                  doc_location:   location })
      raise Error, (message.presence || "Oydid.create returned no result") if result.nil?

      {
        did:            normalize(result["did"]),
        document_key:   result["private_key"],
        revocation_key: result["revocation_key"],
        revocation_log: result["revocation_log"].to_json
      }
    end

    # The Ed25519 public key of a DID's document key, taken from the VDR.
    #
    # The "key" field is positional: slot 0 signs, slot 1 revokes. Index
    # explicitly rather than taking the first element of a split — a further
    # slot would otherwise be picked up silently.
    def public_key(did)
      require "oydid"

      info = Timeout.timeout(RESOLVE_TIMEOUT) { ::Oydid.read(did.to_s, {}).first }
      raise Error, "#{did} does not resolve" if info.nil? || info["error"].to_i != 0

      multibase = info.dig("doc", "key").to_s.split(":")[0]
      raise Error, "#{did} carries no document key" if multibase.blank?

      raw = ::Oydid.multi_decode(multibase).first
      raise Error, "#{did}: unreadable document key" if raw.nil? || raw.bytesize < 32

      raw[-32..]
    rescue Timeout::Error
      raise Error, "#{did} did not answer within #{RESOLVE_TIMEOUT}s"
    end

    # Where a passport DID says it can be read.
    #
    # The decentralised half of reading somebody else's passport: the DID is
    # resolved at the registry, and the address comes out of the document the
    # holder of that DID published. Nothing here decides where a foreign
    # passport lives — the passport does, and this only asks it.
    #
    # A DID with no DigitalProductPassport service entry is not a passport, and
    # saying so is more use than an empty answer.
    def passport_endpoint(did)
      require "oydid"

      info = Timeout.timeout(RESOLVE_TIMEOUT) { ::Oydid.read(did.to_s, {}).first }
      raise Error, "#{did} does not resolve" if info.nil? || info["error"].to_i != 0

      services = Array(info.dig("doc", "doc", "service") || info.dig("doc", "service"))
      entry = services.find { |service| service.is_a?(Hash) && service["type"].to_s == SERVICE_TYPE }
      raise Error, "#{did} is not a product passport" if entry.nil?

      endpoint = entry["serviceEndpoint"].to_s
      raise Error, "#{did} names no address to read it at" if endpoint.blank?

      endpoint
    rescue Timeout::Error
      raise Error, "#{did} did not answer within #{RESOLVE_TIMEOUT}s"
    end

    # Does this private document key belong to that DID? The check that makes
    # importing an identity meaningful rather than hopeful: derive the public key
    # from what was typed in and compare it with what the VDR publishes.
    def key_matches?(did, document_key)
      require "ed25519"

      published = public_key(did)
      derived   = signing_key(document_key).verify_key.to_bytes
      ActiveSupport::SecurityUtils.secure_compare(published, derived)
    end

    # The Ed25519 signing key behind a multibase-encoded private document key.
    #
    # oydid publishes the key as multicodec ed25519-priv: two varint bytes for
    # the code, one for the length, then the 32-byte seed — 35 bytes in all. The
    # documented way to unwrap it is unpack("SCa*"), which assumes exactly that
    # prefix length. Taking the last 32 bytes says the same thing about a
    # well-formed key and does not silently hand back a shifted 29-byte string
    # if the prefix ever differs; a wrong seed there would produce a signature
    # that verifies nowhere, with nothing to point at the cause.
    def signing_key(document_key)
      require "oydid"
      require "ed25519"

      raw = ::Oydid.multi_decode(document_key.to_s).first
      raise Error, "the document key is not readable" if raw.nil? || raw.bytesize < 32

      ::Ed25519::SigningKey.new(raw[-32..])
    end

    def revoke(did, document_key:, revocation_key:)
      require "oydid"

      # oydid decides which branch to take by :doc_enc / :rev_enc but reads the
      # key material from :old_doc_enc / :old_rev_enc, so both have to be set to
      # the same value. Passing :doc_key / :rev_key makes it look for key *files*
      # on disk and fail with a message that points at the keys rather than at
      # the caller.
      _log, message = ::Oydid.revoke(did.to_s, { doc_enc: document_key, old_doc_enc: document_key,
                                                  rev_enc: revocation_key, old_rev_enc: revocation_key,
                                                  key_type: KEY_TYPE,
                                                  doc_location: location })
      raise Error, message if message.to_s.present?
      true
    end
  end
end
