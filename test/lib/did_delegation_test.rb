require "test_helper"
require "base64"

# The mandate an operator signs so that a custodian may hold their passport.
#
# Everything here is arithmetic against a locally generated key, and that is the
# point: this statement is checked by two other implementations — the DPP
# Service before it stores it, and the custodian before it issues a token — and
# neither of them will explain what was wrong in terms this application can act
# on. Whatever can be pinned down here has to be.
class DidDelegationTest < ActiveSupport::TestCase
  SERVICE_DID = "did:oyd:zQmServiceabcdefghijklmnopqrstuvwxyz012345".freeze
  POD = "https://pod.example".freeze
  PRODUCT = "https://id.example.com/01/09520123456788/21/000123".freeze

  setup do
    reset_vault!
    Vault::Lifecycle.create!(TEST_PASSPHRASE)

    require "oydid"
    require "ed25519"
    @signing_key = Ed25519::SigningKey.generate
    encoded = Oydid.multi_encode([ 0, 19, 32 ].pack("C*") + @signing_key.to_bytes,
                                 { encode: "base58btc" }).first
    @identity = Identity.create!(did: "did:oyd:zQmTestbase58subject2345678923456789234567",
                                 origin: "minted", document_key: encoded,
                                 revocation_key: "z1S5Whatever", keys_secured_at: Time.current)
  end

  teardown { Vault::Store.close! }

  test "the header is the one the custodian will accept" do
    header = part(issue.token, 0)

    assert_equal "EdDSA", header["alg"]
    assert_equal "dpp-delegation+jwt", header["typ"],
      "typ is what stops a mandate being replayed as a write token or a client assertion"
    assert_equal "#{@identity.did}#key-doc", header["kid"]
    assert_nil header["cty"]
  end

  test "the claim set says exactly what the mandate is about" do
    claims = issue.claims

    assert_equal @identity.did, claims["iss"], "the custodian checks this against the collection's controller"
    assert_equal SERVICE_DID, claims["sub"], "only the service named here can redeem it"
    assert_equal POD, claims["aud"], "so it cannot be presented at a different custodian"
    assert_equal "7", claims["collection"]
    assert_equal PRODUCT, claims["product_id"]
    assert_equal %w[create update delete], claims["act"]
    assert_equal "dpp-hosting", claims["purpose"]
    assert claims["jti"].present?, "the handle the mandate is revoked by"
    assert_equal claims["iat"], claims["nbf"]
  end

  # Rule 11 / D2: one passport per mandate. A wildcard would turn the binding to
  # an object back into a binding to an account, which is the whole construction.
  test "a mandate without a passport to be about is refused here rather than there" do
    assert_raises(Did::Delegation::Error) { issue(product_id: "") }
    assert_raises(Did::Delegation::Error) { issue(collection: "") }
    assert_raises(Did::Delegation::Error) { issue(audience: "") }
    assert_raises(Did::Delegation::Error) { issue(service_did: "") }
    assert_raises(Did::Delegation::Error) { Did::Delegation.issue(nil, **arguments) }
  end

  test "the lifetime is the one the custodian permits, and it starts now" do
    claims = issue.claims

    assert_equal 90 * 86_400, claims["exp"] - claims["iat"]
    assert_in_delta Time.now.to_i, claims["iat"], 5
  end

  test "the address is written the way the custodian normalises its own" do
    assert_equal POD, issue(audience: "#{POD}/").claims["aud"],
      "a trailing slash would make the audience comparison fail at the pod"
  end

  # Both sides of this protocol have to produce the same signing input from the
  # same claims, so the serialisation is part of the contract rather than a
  # detail of whichever JSON writer happens to be in the process.
  test "what is signed is canonical JSON: sorted keys, no whitespace" do
    payload = Base64.urlsafe_decode64(pad(issue.token.split(".")[1]))

    assert_not payload.include?(" "), "insignificant whitespace changes the signing input"
    assert_equal payload.scan(/"(\w+)":/).flatten, payload.scan(/"(\w+)":/).flatten.sort,
      "the claim names are not in order"
    assert payload.ascii_only?
  end

  test "the signature verifies against the public half of the document key" do
    token = issue.token
    signing_input, signature = token.split(".").then { |a, b, c| [ "#{a}.#{b}", Base64.urlsafe_decode64(pad(c)) ] }

    assert Ed25519::VerifyKey.new(@signing_key.verify_key.to_bytes).verify(signature, signing_input)
  end

  test "it is signed with the identity's own key and no other" do
    other = Ed25519::SigningKey.generate
    token = issue.token
    signing_input, signature = token.split(".").then { |a, b, c| [ "#{a}.#{b}", Base64.urlsafe_decode64(pad(c)) ] }

    assert_raises(Ed25519::VerifyError) do
      Ed25519::VerifyKey.new(other.verify_key.to_bytes).verify(signature, signing_input)
    end
  end

  test "peeking reads back what was signed, and says nothing about anything else" do
    signed = issue

    assert_equal signed.claims, Did::Delegation.peek(signed.token)
    assert_nil Did::Delegation.peek("not a token")
    assert_nil Did::Delegation.peek(nil)
  end

  test "the struct answers the three things a record has to keep" do
    signed = issue

    assert_equal signed.claims["jti"], signed.jti
    assert_equal signed.claims["exp"], signed.expires_at.to_i
    assert_equal %w[create update delete], signed.act
  end

  private

  def arguments(**overrides)
    { audience: POD, collection: "7", product_id: PRODUCT, service_did: SERVICE_DID }.merge(overrides)
  end

  def issue(**overrides) = Did::Delegation.issue(@identity, **arguments(**overrides))

  def part(token, index) = JSON.parse(Base64.urlsafe_decode64(pad(token.split(".")[index])))

  def pad(text) = text + ("=" * ((4 - (text.length % 4)) % 4))
end
