require "test_helper"
require "base64"

# The access grant an operator signs for a reader with a legitimate interest.
#
# The DPP Service checks it (Delegation.verify_access_grant! there) and answers
# a wrong one with a sentence, not with what to change; whatever can be pinned
# down here has to be.
class DidAccessGrantTest < ActiveSupport::TestCase
  SERVICE_DID = "did:oyd:zQmServiceabcdefghijklmnopqrstuvwxyz012345".freeze
  READER = "did:oyd:zQmReaderabcdefghijklmnopqrstuvwxyz0123456".freeze
  PASSPORTS = %w[did:oyd:zQmPassportOne did:oyd:zQmPassportTwo].freeze

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

  test "the header is the one the service takes for an access grant" do
    header = part(issue.token, 0)

    assert_equal "EdDSA", header["alg"]
    assert_equal "dpp-access-grant+jwt", header["typ"],
      "typ is what stops a grant being replayed as a bearer token or a custody mandate"
    assert_equal "#{@identity.did}#key-doc", header["kid"]
  end

  test "the claims grant a legitimate interest, from the operator, to the reader, at this service" do
    claims = issue.claims

    assert_equal @identity.did, claims["iss"], "the owner of the passports"
    assert_equal READER, claims["sub"]
    assert_equal SERVICE_DID, claims["aud"], "so it counts at this service and no other"
    assert_equal [ "legitimateInterest" ], claims["roles"], "authority is not the operator's to give"
    assert_equal PASSPORTS, claims["dpps"]
    assert_not claims.key?("scope")
    assert_equal claims["iat"], claims["nbf"]
    assert_match(/\Agrant-[0-9a-f-]{36}\z/, claims["jti"])
    assert_equal part(issue.token, 1).keys.sort, claims.keys.sort, "the claims shown are the claims signed"
  end

  test "365 days by default, shorter on request, never longer" do
    now = 1_800_000_000
    assert_equal 365 * 86_400, issue(now: now).claims["exp"] - now
    assert_equal 30 * 86_400, issue(days: 30, now: now).claims["exp"] - now
    assert_raises(Did::AccessGrant::Error) { issue(days: 366) }
    assert_raises(Did::AccessGrant::Error) { issue(days: 0) }
    assert_raises(Did::AccessGrant::Error) { issue(days: "a year") }
  end

  test "all my passports is a scope, not a list" do
    claims = issue(dpp_ids: nil, all: true).claims

    assert_equal "issuer", claims["scope"]
    assert_not claims.key?("dpps")
  end

  test "a grant names at least one and at most 1000 passports" do
    assert_raises(Did::AccessGrant::Error) { issue(dpp_ids: []) }
    assert_raises(Did::AccessGrant::Error) { issue(dpp_ids: (1..1001).map { |n| "did:oyd:zQm#{n}" }) }
    assert_equal 1000, issue(dpp_ids: (1..1000).map { |n| "did:oyd:zQm#{n}" }).claims["dpps"].size
  end

  test "the reader is a DID, and not the operator itself" do
    error = assert_raises(Did::AccessGrant::Error) { issue(subject: "Werkstatt Huber") }
    assert_equal "subject_not_a_did", error.message
    error = assert_raises(Did::AccessGrant::Error) { issue(subject: @identity.did) }
    assert_equal "subject_is_issuer", error.message
  end

  test "without the service's DID there is nothing to address the grant to" do
    error = assert_raises(Did::AccessGrant::Error) { issue(service_did: "") }
    assert_equal "no_service_did", error.message
  end

  test "the purpose travels when given, and only plain ASCII" do
    assert_equal "repair", issue(purpose: " repair ").claims["purpose"]
    assert_not issue(purpose: "").claims.key?("purpose")
    error = assert_raises(Did::AccessGrant::Error) { issue(purpose: "Reparatur in Gänserndorf") }
    assert_equal "not_ascii", error.message
  end

  test "the signature verifies against the identity's document key" do
    token = issue.token
    signing_input, signature = token.rpartition(".").values_at(0, 2)

    assert @signing_key.verify_key.verify(Base64.urlsafe_decode64(pad(signature)), signing_input)
  end

  private

  def issue(subject: READER, service_did: SERVICE_DID, dpp_ids: PASSPORTS, all: false, purpose: nil,
            days: Did::AccessGrant::MAX_DAYS, now: Time.now.to_i)
    Did::AccessGrant.issue(@identity, subject: subject, service_did: service_did, dpp_ids: dpp_ids, all: all,
                                      purpose: purpose, days: days, now: now)
  end

  def part(token, index)
    JSON.parse(Base64.urlsafe_decode64(pad(token.split(".")[index])))
  end

  def pad(text) = text + ("=" * ((4 - (text.length % 4)) % 4))
end
