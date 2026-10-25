require "test_helper"

# Handing a passport to the DPP Service.
#
# The service is stubbed at the client seam. What is tested here is the set of
# refusals in front of it — every one of them exists because the corresponding
# failure at the service is unrepairable — and what the application records
# afterwards.
class PassportSubmissionTest < ActionDispatch::IntegrationTest
  SERVICE = "https://dpp-service.example".freeze
  IDENTIFIER = "https://id.example.com/01/09520123456788/21/000123".freeze

  test "a submitted passport records where it went and what came back" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport

      submitting do
        post submit_passport_path(passport)
      end

      assert_redirected_to edit_passport_path(passport)
      passport.reload

      assert passport.submitted?
      assert_equal "submitted", passport.status
      assert_equal SERVICE, passport.submitted_to
      assert_equal "Active", passport.submitted_document["dppStatus"]

      assert Event.where(kind: "passport_submitted").exists?
      assert_nil Event.verify_chain
    end
  end

  # The document is built here and sent as one body. Checking it at this seam
  # rather than only in DppDocumentTest is the difference between "the builder
  # works" and "what the service receives is what the builder made".
  test "what is sent is the document, signed with the operator's identity" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport
      sent = nil

      stubbing(Soya::WebCli, :transform, ->(*) { [] }) do
        stubbing(Did::Token, :issue, ->(_identity, audience:, **) { "token-for-#{audience}" }) do
          stubbing(DppService::Client, :create, ->(document, base_url:, token:, storage: nil, retain_until: nil) {
            sent = { document: document, base_url: base_url, storage: storage,
                     token: token.token_for("POST", "/dpp/v1/dpps", "{}") }
            accepted
          }) do
            post submit_passport_path(passport)
          end
        end
      end

      assert_nil sent[:storage], "without a custodian nobody is granted anything"
      assert_equal passport.dpp_id, sent[:document]["digitalProductPassportId"]
      assert_equal SERVICE, sent[:base_url]
      assert_equal "token-for-#{SERVICE}", sent[:token],
        "the audience is what stops a token issued for one service being replayed at another"
    end
  end

  # The refusal that matters most: the DID's endpoint names a host, the service
  # compares it with its own, and neither side can be corrected afterwards —
  # this service holds no key for a DID it did not mint. Catching it here means
  # the operator reads a sentence rather than a 400.
  test "a passport minted for a different host is not even offered to the service" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport
      passport.update_columns(endpoint_base: "https://pod.example")

      called = false
      stubbing(DppService::Client, :create, ->(*, **) { called = true; accepted }) do
        post submit_passport_path(passport)
      end

      assert_not called, "the submission must not be attempted at all"
      assert_not passport.reload.submitted?
      assert_match "pod.example", flash[:alert]
    end
  end

  test "a passport without an identifier of its own cannot be submitted" do
    with_open_vault do
      create_and_unlock
      passport = ready_passport

      submitting { post submit_passport_path(passport) }

      assert_not passport.reload.submitted?
    end
  end

  test "submitting twice is refused rather than creating a second passport" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport
      submitting { post submit_passport_path(passport) }

      first = passport.reload.submitted_at
      calls = 0
      stubbing(DppService::Client, :create, ->(*, **) { calls += 1; accepted }) do
        post submit_passport_path(passport)
      end

      assert_equal 0, calls
      assert_equal first, passport.reload.submitted_at
    end
  end

  test "a refusal from the service is shown with its own words and changes nothing here" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport

      refusal = DppService::Client::Result.new(ok: false, http_status: 400,
                                               problems: [ "granularity does not match the path" ])
      submitting(create: ->(*, **) { refusal }) { post submit_passport_path(passport) }

      assert_not passport.reload.submitted?
      assert_match "granularity does not match the path", flash[:alert]
      assert Event.where(kind: "passport_submit_failed").exists?
    end
  end

  test "a service that cannot be reached is said so, not swallowed" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport

      submitting(create: ->(*, **) { raise DppService::Client::Error, "timeout" }) do
        post submit_passport_path(passport)
      end

      assert_not passport.reload.submitted?
      assert flash[:alert].present?
    end
  end

  test "a type whose transformation was never fetched says which step is missing" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport
      passport.product_type.update_columns(transformation_fetched_at: nil, transformation_jsonld: nil)

      post submit_passport_path(passport)

      assert_not passport.reload.submitted?
      assert_match I18n.t("passports.submit.reasons.transformation_not_fetched"), flash[:alert]
    end
  end

  # What "submitted" records: the fingerprint of what was sent. Without it the
  # page could not tell a passport that matches the service from one that has
  # been edited since, and would have to guess.
  test "submitting records what was sent, so nothing looks changed straight after" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport
      submitting { post submit_passport_path(passport) }

      passport.reload
      assert passport.submitted_digest.present?
      assert_not passport.differs_from_service?
    end
  end

  # The form comes back after submitting: the answer to "what did I get wrong"
  # has to be the same form that got it wrong.
  test "a submitted passport can be filled in again" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport
      submitting { post submit_passport_path(passport) }

      get edit_passport_path(passport)
      assert_response :success
      assert_select "iframe.soya-frame", 1
      assert_match SERVICE, response.body
    end
  end

  private

  # --- attesting the payload (EN 18246:2026, variant B) ------------------------
  #
  # The service computes the hash of what the custodian delivers and reports it,
  # but it cannot sign the entry that commits to it: the document key is here.

  def commitment_result(state, hash = "zQmPayload")
    DppService::Client::Result.new(ok: true, http_status: 201, problems: [],
                                   document: { "dppStatus" => "Active" },
                                   commitment: DppService::Client::Commitment.new(
                                     payload_hash: hash, state: state
                                   ))
  end

  test "a submission attests the payload, with the keys that never leave this machine" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport
      seen = nil

      submitting(create: ->(*, **) { commitment_result("pending") }) do
        stubbing(Did::Oyd, :commit_payload, lambda { |did, payload_hash:, document_key:, revocation_key:|
          seen = { did: did, hash: payload_hash, doc: document_key, rev: revocation_key }
          { did: did, revocation_log: '[{"op":1}]' }
        }) do
          post submit_passport_path(passport)
        end
      end

      passport.reload
      assert_equal passport.dpp_id, seen[:did]
      assert_equal "zQmPayload", seen[:hash]
      assert_equal "doc", seen[:doc], "the service never sees this key, which is the whole point"
      assert_equal "rev", seen[:rev]

      assert_equal "zQmPayload", passport.payload_hash
      assert passport.payload_attested?
      assert_equal '[{"op":1}]', passport.passport_key.reload.revocation_log,
        "the revocation record belongs to the new document, or the passport can never be retired"
      assert Event.where(kind: "passport_payload_attested").exists?
      assert_nil Event.verify_chain
    end
  end

  # The passport is already with the service by then. A registry that cannot be
  # reached must not turn a submission that worked into one that failed.
  test "a registry that refuses the entry leaves the passport waiting and the submission standing" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport

      submitting(create: ->(*, **) { commitment_result("pending") }) do
        stubbing(Did::Oyd, :commit_payload, ->(*, **) { raise Did::Oyd::Error, "unreachable" }) do
          post submit_passport_path(passport)
        end
      end

      passport.reload
      assert passport.submitted?, "the submission is done and stays done"
      assert passport.payload_awaiting_attestation?
      assert_equal "zQmPayload", passport.payload_hash
      assert Event.where(kind: "passport_payload_attestation_failed").exists?
      assert_match I18n.t("passports.attest.waiting"), flash[:notice]
    end
  end

  # A service that holds the document key itself has already written the entry.
  # Asking this machine to sign it again would fail, and calling it "waiting"
  # would be a lie about a document that does commit to the payload.
  test "a payload the service has already committed to is not attested a second time" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport
      called = false

      submitting(create: ->(*, **) { commitment_result("committed") }) do
        stubbing(Did::Oyd, :commit_payload, ->(*, **) { called = true; nil }) do
          post submit_passport_path(passport)
        end
      end

      passport.reload
      assert_not called
      assert passport.payload_attested?
      assert_equal "zQmPayload", passport.payload_hash
    end
  end

  # An older service says nothing about a commitment. Nothing is recorded, and
  # nothing claims to be waiting.
  test "a service that reports no commitment leaves the passport as it was" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport
      called = false

      submitting do
        stubbing(Did::Oyd, :commit_payload, ->(*, **) { called = true; nil }) do
          post submit_passport_path(passport)
        end
      end

      passport.reload
      assert_not called
      assert_nil passport.payload_hash
      assert_not passport.payload_awaiting_attestation?
    end
  end

  # The way back for a passport the registry would not take at the time. The
  # service cannot do this instead, which is why there is a button at all.
  def waiting_passport
    passport = minted_passport
    submitting(create: ->(*, **) { commitment_result("pending") }) do
      stubbing(Did::Oyd, :commit_payload, ->(*, **) { raise Did::Oyd::Error, "unreachable" }) do
        post submit_passport_path(passport)
      end
    end
    passport.reload
  end

  test "a passport left waiting can be attested afterwards" do
    with_open_vault do
      create_and_unlock
      passport = waiting_passport
      assert passport.payload_awaiting_attestation?

      get edit_passport_path(passport)
      assert_match "zQmPayload", response.body, "the page says which hash is waiting"

      stubbing(Did::Oyd, :commit_payload, ->(*, **) { { did: passport.dpp_id, revocation_log: "[]" } }) do
        post attest_passport_path(passport)
      end

      assert_redirected_to edit_passport_path(passport)
      assert passport.reload.payload_attested?
      assert Event.where(kind: "passport_payload_attested").exists?
      assert_nil Event.verify_chain
    end
  end

  test "a refusal on the second attempt is shown with the reason and changes nothing" do
    with_open_vault do
      create_and_unlock
      passport = waiting_passport

      stubbing(Did::Oyd, :commit_payload, ->(*, **) { raise Did::Oyd::Error, "invalid old key" }) do
        post attest_passport_path(passport)
      end

      assert_match "invalid old key", flash[:alert]
      assert passport.reload.payload_awaiting_attestation?
    end
  end

  test "attesting twice is answered rather than signed again" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport
      called = false

      submitting(create: ->(*, **) { commitment_result("pending") }) do
        stubbing(Did::Oyd, :commit_payload, ->(*, **) { { did: passport.dpp_id, revocation_log: "[]" } }) do
          post submit_passport_path(passport)
        end
      end

      stubbing(Did::Oyd, :commit_payload, ->(*, **) { called = true; nil }) do
        post attest_passport_path(passport)
      end

      assert_not called
      assert_match I18n.t("passports.attest.already"), flash[:notice]
    end
  end

  test "there is nothing to attest before the service has reported a hash" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport

      post attest_passport_path(passport)

      assert_match I18n.t("passports.attest.nothing"), flash[:alert]
    end
  end

  # The structure's rules have to hold at the moment the passport leaves this
  # machine, and not before: a draft may be half typed. So the check sits here,
  # and nowhere on the way to here.
  test "a passport that does not meet its structure is not submitted" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport
      called = false
      invalid = Soya::Validation::Result.new(valid: false, problems: [ "Leistung (W): fehlt" ])

      stubbing(Soya::Validation, :check, ->(*) { invalid }) do
        submitting(create: ->(*, **) { called = true; accepted }) do
          post submit_passport_path(passport)
        end
      end

      assert_not called, "the submission must not be attempted at all"
      assert_not passport.reload.submitted?
      assert_redirected_to edit_passport_path(passport, despite: "submit")
      assert_equal [ "Leistung (W): fehlt" ], flash[:problems]
      assert Event.where(kind: "passport_submit_failed").exists?
    end
  end

  # Refused, not blocked. The structure itself can be wrong, and then the
  # operator has to be able to overrule the application — visibly.
  test "it goes anyway on a second, deliberate click, and the log says so" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport
      invalid = Soya::Validation::Result.new(valid: false, problems: [ "Leistung (W): fehlt" ])

      stubbing(Soya::Validation, :check, ->(*) { invalid }) do
        submitting do
          post submit_passport_path(passport, despite_problems: 1)
        end
      end

      assert passport.reload.submitted?
      assert_equal true, Event.where(kind: "passport_submitted").last.detail_hash["despite_problems"]
      assert_nil Event.verify_chain
    end
  end

  def product_type
    @product_type ||= ProductType.create!(
      label: "Lamp", structure_name: "DppLedLamp", repo_base_url: "https://soya.example",
      jsonld: '{"@graph":[]}',
      forms: { "en" => { "schema" => { "properties" => { "watt" => { "type" => "integer" } } }, "ui" => {} } }.to_json,
      fetched_at: Time.current,
      transformation_name: "DppLedLampToEN18223",
      transformation_jsonld: '{"@graph":[]}', transformation_fetched_at: Time.current
    )
  end

  def ready_passport
    Setting.current.update!(service_base_url: SERVICE, service_audience: SERVICE)
    Identity.first || Identity.create!(did: "did:oyd:zQmWxYzabcdefgh", origin: "minted", document_key: "k")
    Passport.create!(product_type: product_type, label: "Batch A", data: '{"watt":9}',
                     unique_product_identifier: IDENTIFIER, granularity: "item")
  end

  def minted_passport
    passport = ready_passport
    stubbing(Did::Oyd, :mint_passport, ->(*, **) {
      { did: "did:oyd:zQmPassport#{passport.id}", document_key: "doc", revocation_key: "rev", revocation_log: "[]" }
    }) do
      post mint_passport_path(passport)
    end
    passport.reload
  end

  def accepted
    DppService::Client::Result.new(ok: true, http_status: 201, problems: [],
                                   document: { "dppStatus" => "Active" })
  end

  # The three seams that need the outside world: the transformation runs in
  # soya-web-cli, the token needs a real key, and the create call needs the
  # service. Replaced together, because a test that stubs two of the three fails
  # on the third for a reason that has nothing to do with what it is testing.
  def submitting(create: ->(*, **) { accepted }, &block)
    stubbing(Soya::WebCli, :transform, ->(*) { [] }) do
      stubbing(DppService::Client, :create, create) do
        stubbing(Did::Token, :issue, ->(*, **) { "token" }, &block)
      end
    end
  end
end
