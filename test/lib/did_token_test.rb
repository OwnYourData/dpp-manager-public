require "test_helper"

# The token contract, checked against a locally generated key rather than
# against the registry: everything here is arithmetic, and none of it needs the
# network. The one thing that does — resolving the DID — is what
# Did::Token.self_test covers, and that is exercised in the wizard, not here.
class DidTokenTest < ActiveSupport::TestCase
  setup do
    reset_vault!
    Vault::Lifecycle.create!(TEST_PASSPHRASE)

    require "oydid"
    require "ed25519"
    @signing_key = Ed25519::SigningKey.generate
    # The shape oydid actually publishes: multicodec ed25519-priv (two varint
    # bytes) plus a length byte plus the 32-byte seed. Measured against a real
    # key from Oydid.create, not guessed — multi_encode alone omits the prefix.
    encoded = Oydid.multi_encode([ 0, 19, 32 ].pack("C*") + @signing_key.to_bytes,
                                 { encode: "base58btc" }).first
    @identity = Identity.create!(did: "did:oyd:zQmTestbase58subject2345678923456789234567",
                                 origin: "minted", document_key: encoded,
                                 revocation_key: "z1S5Whatever", keys_secured_at: Time.current)
  end

  teardown { Vault::Store.close! }

  test "the token carries exactly what the service checks" do
    token = Did::Token.issue(@identity, audience: "https://dpp-service.example")
    payload, header = JWT.decode(token, nil, false)

    assert_equal "EdDSA", header["alg"]
    assert_equal "#{@identity.did}#key-doc", header["kid"]
    assert_equal @identity.did, payload["iss"]
    assert_equal payload["iss"], payload["sub"], "the token is self-issued"
    assert_equal "https://dpp-service.example", payload["aud"]
    assert payload["jti"].present?
  end

  test "the lifetime never exceeds what the service accepts" do
    token = Did::Token.issue(@identity, audience: "https://x.example", lifetime: 99_999)
    payload, = JWT.decode(token, nil, false)

    assert_operator payload["exp"] - payload["iat"], :<=, Did::Token::MAX_LIFETIME
  end

  test "the signature verifies against the public half of the document key" do
    token = Did::Token.issue(@identity, audience: "https://x.example")
    verify_key = Ed25519::VerifyKey.new(@signing_key.verify_key.to_bytes)

    assert JWT.decode(token, verify_key, true, algorithm: "EdDSA",
                                               aud: "https://x.example", verify_aud: true)
  end

  test "it is signed with the document key, not with anything else" do
    other = Ed25519::SigningKey.generate
    token = Did::Token.issue(@identity, audience: "https://x.example")

    assert_raises(JWT::VerificationError) do
      JWT.decode(token, Ed25519::VerifyKey.new(other.verify_key.to_bytes), true, algorithm: "EdDSA")
    end
  end

  test "an audience is required — a token without one is refused everywhere" do
    assert_raises(ArgumentError) { Did::Token.issue(@identity, audience: nil) }
  end

  # A real key from Oydid.create decodes to 35 bytes: two varint bytes for the
  # multicodec, one length byte, then the seed. Both ways of unwrapping it have
  # to agree, or a token is signed with a key nobody can check.
  test "the documented unwrapping and the one used here yield the same key" do
    raw = Oydid.multi_decode(@identity.document_key).first
    _code, _len, documented = raw.unpack("SCa*")

    assert_equal 35, raw.bytesize
    assert_equal documented, raw[-32..]
    assert_equal @signing_key.to_bytes, Did::Oyd.signing_key(@identity.document_key).to_bytes
  end

  test "an unreadable document key is refused rather than silently truncated" do
    assert_raises(Did::Oyd::Error) { Did::Oyd.signing_key("z1S5tooShort") }
  end
end
