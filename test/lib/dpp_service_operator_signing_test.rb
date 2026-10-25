require "test_helper"

# Signing a passport as its economic operator, with the service stubbed at the
# client seam and a key generated here. What is checked is what the DPP Service
# checks: the JWS carries exactly the bytes that were read, names the document
# key of the identity, and verifies with it.
class DppServiceOperatorSigningTest < ActiveSupport::TestCase
  SERVICE = "https://dpp-service.example".freeze
  DPP_ID = "did:oyd:zQmPassport".freeze
  CHANGED = "Signature refused: the payload is not the passport as it is delivered now (its public part in the " \
            "full representation); a write may have come in between: fetch it again and sign that".freeze

  setup do
    reset_vault!
    Vault::Lifecycle.create!(TEST_PASSPHRASE)

    require "oydid"
    require "ed25519"
    @signing_key = Ed25519::SigningKey.generate
    encoded = Oydid.multi_encode([ 0, 19, 32 ].pack("C*") + @signing_key.to_bytes, { encode: "base58btc" }).first
    @identity = Identity.create!(did: "did:oyd:zQmTestbase58subject2345678923456789234567",
                                 origin: "minted", document_key: encoded,
                                 revocation_key: "z1S5Whatever", keys_secured_at: Time.current)
  end

  teardown { Vault::Store.close! }

  test "the passport is signed as it was read, with the document key of the identity" do
    read = %({"digitalProductPassportId":"#{DPP_ID}","lastUpdated":"2026-10-25T10:00:00Z","elements":[]})
    handed = []

    outcome = service(reads: [ read ], answers: [ accepted ], handed: handed) { sign }

    assert outcome.ok?
    assert_equal "signed", outcome.state
    assert_equal 1, outcome.attempts
    head, body, signature = handed.first[:compact].split(".")
    assert_equal({ "alg" => "EdDSA", "kid" => "#{@identity.did}#key-doc" }, JSON.parse(decode(head)))
    assert_equal read, decode(body), "the bytes the service delivered, not a new serialisation of them"
    assert @signing_key.verify_key.verify(decode(signature), "#{head}.#{body}")
    assert_equal({ base_url: SERVICE, dpp_id: DPP_ID }, handed.first.slice(:base_url, :dpp_id))
    assert_kind_of Did::Token::Bearer, handed.first[:token]
  end

  test "a write that came in between is read and signed again" do
    handed = []
    changed = refusal(400, CHANGED)

    outcome = service(reads: [ %({"v":1}), %({"v":2}) ], answers: [ changed, accepted ], handed: handed) { sign }

    assert outcome.ok?
    assert_equal 2, outcome.attempts
    assert_equal %({"v":2}), decode(handed.last[:compact].split(".")[1]), "the second signature covers the second read"
  end

  test "it gives up after a few attempts and reports the service's sentence" do
    changed = refusal(400, CHANGED)
    attempts = DppService::OperatorSigning::ATTEMPTS

    outcome = service(reads: [ "{}" ] * attempts, answers: [ changed ] * attempts) { sign }

    assert_not outcome.ok?
    assert_equal attempts, outcome.attempts
    assert_equal [ CHANGED ], outcome.problems
  end

  test "any other refusal is reported at once" do
    forbidden = refusal(403, "Signature refused: only the economic operator that created this passport may sign it")

    outcome = service(reads: [ "{}", "{}" ], answers: [ forbidden, accepted ]) { sign }

    assert_not outcome.ok?
    assert_equal 1, outcome.attempts
    assert_match "only the economic operator", outcome.problems.first
  end

  test "a passport that cannot be read is not signed" do
    missing = DppService::Client::Result.new(ok: false, http_status: 404, problems: [ "no such passport" ])
    handed = []

    outcome = service(reads: [ missing ], answers: [], handed: handed) { sign }

    assert_not outcome.ok?
    assert_empty handed
    assert_equal [ "no such passport" ], outcome.problems
  end

  test "the warning on a representative's signature comes back with the outcome" do
    warning = "signed by #{@identity.did}, which is not the economicOperatorId did:oyd:zQmOther: accepted"
    with_warning = DppService::Client::Result.new(ok: true, http_status: 200, problems: [], warnings: [ warning ],
                                                  signature_state: "signed")

    outcome = service(reads: [ "{}" ], answers: [ with_warning ]) { sign }

    assert outcome.ok?
    assert_equal [ warning ], outcome.warnings
  end

  private

  def sign
    DppService::OperatorSigning.call(base_url: SERVICE, dpp_id: DPP_ID, identity: @identity, audience: SERVICE)
  end

  def service(reads:, answers:, handed: [], &block)
    reads = reads.map do |read|
      read.is_a?(String) ? DppService::Client::Result.new(ok: true, http_status: 200, problems: [], raw: read) : read
    end
    stubbing(DppService::Client, :read_for_signing, ->(base_url:, dpp_id:) { reads.shift }) do
      stubbing(DppService::Client, :submit_signature, lambda { |compact, base_url:, dpp_id:, token:|
        handed << { compact: compact, base_url: base_url, dpp_id: dpp_id, token: token }
        answers.shift
      }, &block)
    end
  end

  def accepted
    DppService::Client::Result.new(ok: true, http_status: 200, problems: [], warnings: [], signature_state: "signed")
  end

  def refusal(status, text)
    DppService::Client::Result.new(ok: false, http_status: status, problems: [ text ], signature_state: "pending")
  end

  def decode(part) = Base64.urlsafe_decode64(part + "=" * ((4 - part.size % 4) % 4))
end
