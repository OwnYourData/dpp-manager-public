require "test_helper"

# What this application asks oydid for when it mints an identity.
#
# Every one of these options has a failure mode that is silent: leave one out
# and a DID still comes back, correct-looking, and wrong in a way that shows up
# somewhere else entirely — in a token the service refuses, in an identifier
# that cannot be resolved, or in a document a conformant verifier will not use.
# So the call itself is asserted, not just its result.
class DidOydTest < ActiveSupport::TestCase
  # The gem is loaded lazily inside mint (`require "oydid"`), so the constant
  # does not exist until something has minted. Stubbing it before that would
  # define it as an empty module and hide whatever the real one does.
  setup { require "oydid" }

  RESULT = {
    "did" => "did:oyd:zQmTestIdentity@https://oydid.ownyourdata.eu",
    "private_key" => "z6MkDocumentKey",
    "revocation_key" => "z6MkRevocationKey",
    "revocation_log" => [ { "op" => 1 } ]
  }.freeze

  test "minting names the key type, the location twice, and the authentication relation" do
    options = capture_create_options

    assert_equal "ed25519", options[:key_type],
      "oydid defaults to no key type and raises inside generate_base without one"

    assert_equal Did::Oyd.location, options[:location],
      "without :location the identifier loses its repository suffix"
    assert_equal Did::Oyd.location, options[:doc_location],
      "without :doc_location the document is not published where the DID says it is"

    assert options[:return_secrets],
      "the document and revocation keys exist only in this return value"
  end

  # The one that cannot be corrected later. The section sits inside the hashed
  # payload, so a DID minted without it can only gain it by being minted again
  # under a different identifier.
  test "the identity DID asserts the key it authenticates with" do
    assert_equal true, capture_create_options[:authentication],
      "an identifier whose whole purpose is authenticating to a service has to say so"
  end

  # The identity signs the passports the DPP Service keeps, as their economic
  # operator, so its document says that the document key asserts too. Like
  # authentication, it sits inside the hashed payload: right at minting, or not
  # at all.
  test "the identity DID declares its document key for assertions" do
    seen = nil
    stubbing(::Oydid, :create, ->(content, _options) { seen = content; [ RESULT, nil ] }) { Did::Oyd.mint }

    assert_equal [ "#key-doc" ], seen["assertionMethod"]
  end

  test "a passport DID declares no assertion method" do
    content = capture_passport_content("https://id.example.com/01/09520123456788", endpoint_base: "https://pod.example")

    assert_not content.key?("assertionMethod"), "a passport names a thing; the identity signs on its behalf"
  end

  # --- attesting the payload (variant B) --------------------------------------
  #
  # The service computes the hash and reports it; it cannot sign the entry,
  # because the document key is here. Every option below has the same silent
  # failure mode as the minting ones, and one of them is worse: leave the old
  # revocation key out and oydid complains about the *document* key.

  PUBLISHED = {
    "error" => 0,
    "doc" => { "key" => "z6MkDoc:z6MkRev",
               "doc" => { "service" => [ { "type" => "DigitalProductPassport",
                                           "serviceEndpoint" => "https://pod.example/dpp/v1/dppsByProductId/x" } ] } }
  }.freeze

  def attesting(published: PUBLISHED, result: RESULT, message: nil, hash: "zQmPayload")
    seen = { called: false }
    copy = Marshal.load(Marshal.dump(published))
    stubbing(::Oydid, :read, ->(_did, _options) { [ copy, nil ] }) do
      stubbing(::Oydid, :update, lambda { |content, did, options|
        seen = { called: true, content: content, did: did, options: options }
        [ result, message ]
      }) do
        # Deliberately in two steps: `seen[:returned] = ...` would evaluate the
        # receiver first, and the call on the right rebinds `seen` inside the
        # stub — the key would land on the hash that is no longer returned.
        returned = Did::Oyd.commit_payload("did:oyd:zQmPassport", payload_hash: hash,
                                                                 document_key: "z6MkDoc",
                                                                 revocation_key: "z6MkRev")
        seen[:returned] = returned
        seen
      end
    end
  end

  test "attesting hands oydid both old keys and keeps the pair the operator wrote down" do
    options = attesting[:options]

    assert_equal "z6MkDoc", options[:old_doc_enc]
    assert_equal "z6MkRev", options[:old_rev_enc],
      "an update rebuilds the revocation record of the previous document and signs it with this key"
    assert_equal "z6MkDoc", options[:doc_enc],
      "without this oydid generates a fresh pair and the stored secrets stop matching the document"
    assert_equal "z6MkRev", options[:rev_enc]
    assert_equal false, options[:authentication],
      "oydid rebuilds the document on every write and would add an authentication method"
    assert_equal "ed25519", options[:key_type]
    assert_equal Did::Oyd.location, options[:doc_location]
  end

  # The document is read and extended. Rebuilding it from configuration would
  # drop whatever else it carries — including a commitment it already had.
  test "the hash goes into the service entry the passport already published" do
    content = attesting[:content]
    entry = content["service"].first

    assert_equal "zQmPayload", entry["payloadHash"]
    assert_equal "https://pod.example/dpp/v1/dppsByProductId/x", entry["serviceEndpoint"],
      "the address the passport is read at is none of this operation's business"
    assert_not content.key?("key"),
      "oydid rebuilds the key field on every write; feeding it back in publishes it as content"
  end

  test "the revocation log that comes back has to be stored, so it is returned" do
    assert_equal '[{"op":1}]', attesting[:returned][:revocation_log]
  end

  test "a document that already attests this payload is left alone" do
    published = Marshal.load(Marshal.dump(PUBLISHED))
    published["doc"]["doc"]["service"].first["payloadHash"] = "zQmPayload"

    seen = attesting(published: published)

    assert_nil seen[:returned]
    assert_not seen[:called], "writing an entry that changes nothing is not an update"
  end

  test "a DID that carries no passport entry is refused rather than given one" do
    published = Marshal.load(Marshal.dump(PUBLISHED))
    published["doc"]["doc"]["service"] = [ { "type" => "SomethingElse" } ]

    error = assert_raises(Did::Oyd::Error) { attesting(published: published) }
    assert_match(/not a product passport/, error.message)
  end

  test "attesting nothing is refused, because an empty hash would attest an empty payload" do
    error = assert_raises(Did::Oyd::Error) { attesting(hash: "  ") }
    assert_match(/no payload hash/, error.message)
  end

  test "a refusal while attesting becomes an error carrying what oydid said" do
    error = assert_raises(Did::Oyd::Error) do
      attesting(result: nil, message: "invalid or missing old private document key")
    end
    assert_equal "invalid or missing old private document key", error.message
  end

  # --- moving the endpoint (handover to another custodian) -------------------
  #
  # Same read-and-change rule as attesting: the endpoint is the only thing a
  # handover changes. A document rebuilt from scratch would drop the payload
  # commitment it already carries (BCK-005).

  def moving(published: PUBLISHED, result: RESULT, message: nil)
    seen = { called: false }
    copy = Marshal.load(Marshal.dump(published))
    stubbing(::Oydid, :read, ->(_did, _options) { [ copy, nil ] }) do
      stubbing(::Oydid, :update, lambda { |content, did, options|
        seen = { called: true, content: content, did: did, options: options }
        [ result, message ]
      }) do
        returned = Did::Oyd.move_endpoint("did:oyd:zQmPassport", product_id: "https://id.example/01/09520123456788",
                                                                endpoint_base: "https://new-pod.example",
                                                                document_key: "z6MkDoc", revocation_key: "z6MkRev")
        seen[:returned] = returned
        seen
      end
    end
  end

  test "a handover keeps the payload commitment the passport already carries" do
    published = Marshal.load(Marshal.dump(PUBLISHED))
    published["doc"]["doc"]["service"].first["payloadHash"] = "zQmPayload"

    entry = moving(published: published)[:content]["service"].first

    assert_equal "zQmPayload", entry["payloadHash"],
      "a rebuilt entry would withdraw the attestation with every handover"
    assert_equal "https://new-pod.example/dpp/v1/dppsByProductId/https%3A%2F%2Fid.example%2F01%2F09520123456788",
      entry["serviceEndpoint"]
  end

  test "a handover leaves every other part of the document as it was" do
    published = Marshal.load(Marshal.dump(PUBLISHED))
    published["doc"]["doc"]["service"] << { "type" => "LinkedDomains", "serviceEndpoint" => "https://operator.example" }
    published["doc"]["doc"]["note"] = "kept"

    content = moving(published: published)[:content]

    assert_equal "kept", content["note"]
    assert_equal "https://operator.example", content["service"].last["serviceEndpoint"]
    assert_not content.key?("key"), "oydid's own bookkeeping is not content"
  end

  test "a handover hands oydid both old keys and adds no authentication method" do
    options = moving[:options]

    assert_equal "z6MkDoc", options[:old_doc_enc]
    assert_equal "z6MkRev", options[:old_rev_enc]
    assert_equal "z6MkDoc", options[:doc_enc]
    assert_equal "z6MkRev", options[:rev_enc]
    assert_equal false, options[:authentication]
  end

  test "a DID without a passport entry is not moved" do
    published = Marshal.load(Marshal.dump(PUBLISHED))
    published["doc"]["doc"]["service"] = [ { "type" => "SomethingElse" } ]

    error = assert_raises(Did::Oyd::Error) { moving(published: published) }
    assert_match(/not a product passport/, error.message)
  end

  test "the repository suffix is stripped from the identifier that goes into tokens" do
    stubbing(::Oydid, :create, ->(_content, _options) { [ RESULT, nil ] }) do
      assert_equal "did:oyd:zQmTestIdentity", Did::Oyd.mint[:did]
    end
  end

  # oydid reports failure by returning nil and a message beside it, rather than
  # raising. Passing that through as an exception is what stops a nil result
  # from being stored as an identity.
  test "a refusal from oydid becomes an error carrying what oydid said" do
    stubbing(::Oydid, :create, ->(_content, _options) { [ nil, "public key already controls an active DID" ] }) do
      error = assert_raises(Did::Oyd::Error) { Did::Oyd.mint }
      assert_equal "public key already controls an active DID", error.message
    end
  end

  # --- the passport's DID -----------------------------------------------------

  # The service entry is what makes it a passport DID rather than any other DID:
  # the DPP Service resolves it on submission and refuses one without an entry of
  # this type. The endpoint is built character for character the way the service
  # builds its own, escaping included, so that a passport minted here and one
  # minted there are the same thing.
  test "a passport DID carries the service entry the DPP Service looks for" do
    content = capture_passport_content("https://id.example.com/01/09520123456788",
                                       endpoint_base: "https://dpp-service.example")

    entry = content["service"].first
    assert_equal "DigitalProductPassport", entry["type"]
    assert_equal "https://dpp-service.example/dpp/v1/dppsByProductId/" \
                 "#{CGI.escape('https://id.example.com/01/09520123456788')}",
                 entry["serviceEndpoint"]
  end

  # The mirror image of the identity's `authentication: true`, and deliberate: a
  # passport DID names a thing, not an actor. It never signs anything — the
  # operator's identity signs on its behalf — so asserting a verification
  # relationship it will never exercise would be a claim about the document that
  # is simply untrue.
  test "a passport DID asserts no authentication relation" do
    options = nil
    stubbing(::Oydid, :create, ->(_content, opts) { options = opts; [ RESULT, nil ] }) do
      Did::Oyd.mint_passport("https://id.example.com/01/09520123456788",
                             endpoint_base: "https://dpp-service.example")
    end

    assert_equal false, options[:authentication]
    assert_equal "ed25519", options[:key_type]
    assert options[:return_secrets]
  end

  test "a trailing slash on the endpoint base does not become a double slash" do
    content = capture_passport_content("https://id.example.com/01/09520123456788",
                                       endpoint_base: "https://dpp-service.example/")

    assert_includes content["service"].first["serviceEndpoint"], "example/dpp/v1/"
  end

  # Both of these would mint a real, published, useless DID: one pointing at
  # nothing, one naming no product. Refusing before the registrar is called is
  # the only cheap moment.
  test "minting without a product identifier or without an endpoint is refused" do
    assert_raises(Did::Oyd::Error) { Did::Oyd.mint_passport("", endpoint_base: "https://dpp-service.example") }
    assert_raises(Did::Oyd::Error) { Did::Oyd.mint_passport("https://id.example.com/01/09520123456788", endpoint_base: " ") }
  end

  private

  def capture_create_options
    seen = nil
    stubbing(::Oydid, :create, ->(_content, options) { seen = options; [ RESULT, nil ] }) { Did::Oyd.mint }
    seen
  end

  def capture_passport_content(product_id, endpoint_base:)
    seen = nil
    stubbing(::Oydid, :create, ->(content, _options) { seen = content; [ RESULT, nil ] }) do
      Did::Oyd.mint_passport(product_id, endpoint_base: endpoint_base)
    end
    seen
  end
end
