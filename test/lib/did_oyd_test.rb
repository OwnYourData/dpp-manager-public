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
