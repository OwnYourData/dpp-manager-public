require "test_helper"

# The signature of the economic operator on a passport the DPP Service keeps in
# its own database: handed in after every write, shown on the passport page,
# and offered again where it did not go through. The signing itself is stubbed
# at DppService::OperatorSigning, whose own test checks the JWS.
class PassportSignatureTest < ActionDispatch::IntegrationTest
  SERVICE = "https://dpp-service.example".freeze
  IDENTIFIER = "https://id.example.com/01/09520123456788/21/000321".freeze

  test "a passport the service keeps is signed right after it is submitted" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport
      asked = []

      signing(->(**args) { asked << args; signed }) do
        submitting(create: ->(*, **) { accepted(signature_state: "none") }) { post submit_passport_path(passport) }
      end

      passport.reload
      assert_equal 1, asked.size
      assert_equal({ base_url: SERVICE, dpp_id: passport.dpp_id, audience: SERVICE },
                   asked.first.slice(:base_url, :dpp_id, :audience))
      assert_equal Identity.current, asked.first[:identity]
      assert passport.signed?
      assert_nil passport.signature_problem
      assert Event.where(kind: "passport_signed").exists?
      assert_includes flash[:notice], I18n.t("passports.signature.done")
      assert_nil Event.verify_chain
    end
  end

  test "a correction is signed again, and the page shows the state" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport
      passport.update!(answers_hash_change)
      states = []

      signing(->(**) { states << passport.reload.signature_state; signed }) do
        correcting(update: ->(*, **) { accepted(signature_state: "pending", status: 200) }) do
          post correct_passport_path(passport)
        end
      end

      assert_equal [ "pending" ], states, "what the service said after the write is recorded before signing"
      assert passport.reload.signed?

      get edit_passport_path(passport)
      assert_select "#signature dd", text: I18n.t("passports.signature.states.signed")
      assert_select "#signature form[action=?]", sign_passport_path(passport), count: 0
    end
  end

  test "a service that reports no signature state is not asked for a signature" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport
      called = false

      signing(->(**) { called = true; signed }) do
        submitting { post submit_passport_path(passport) }
      end

      assert_not called
      assert_nil passport.reload.signature_state
    end
  end

  test "a signature that does not go through leaves the submission done, and is offered again" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport
      failed = DppService::OperatorSigning::Outcome.new(ok: false, state: "none", warnings: [],
                                                        problems: [ "the DPP Service could not be reached" ])

      signing(->(**) { failed }) do
        submitting(create: ->(*, **) { accepted(signature_state: "none") }) { post submit_passport_path(passport) }
      end

      passport.reload
      assert passport.submitted?, "the write is done; only the signature is missing"
      assert_not passport.signed?
      assert_equal "the DPP Service could not be reached", passport.signature_problem
      assert Event.where(kind: "passport_signature_failed").exists?

      get edit_passport_path(passport)
      assert_select "#signature form[action=?]", sign_passport_path(passport)
      assert_match "the DPP Service could not be reached", response.body

      signing(->(**) { signed }) { post sign_passport_path(passport) }

      assert passport.reload.signed?
      assert_nil passport.signature_problem
      assert_equal I18n.t("passports.signature.done"), flash[:notice]
    end
  end

  test "a signature accepted as a representative's says so on the page" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport
      warning = "signed by did:oyd:zQmMe, which is not the economicOperatorId did:oyd:zQmOther: accepted"

      signing(->(**) { signed(warnings: [ warning ]) }) { post sign_passport_path(passport) }

      assert_equal I18n.t("passports.signature.done_representative"), flash[:notice]
      get edit_passport_path(passport)
      assert_match I18n.t("passports.signature.representative"), response.body
      assert_match "which is not the economicOperatorId", response.body
    end
  end

  test "a passport at a custodian is not signed, and its page says why" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport
      passport.update_columns(custodian_collection_id: "4")
      called = false

      signing(->(**) { called = true; signed }) { post sign_passport_path(passport) }

      assert_not called
      assert_equal I18n.t("passports.signature.custodial"), flash[:alert]
      get edit_passport_path(passport)
      assert_select "#signature p", text: I18n.t("passports.signature.custodial")
      assert_select "#signature form", count: 0
    end
  end

  test "all passports that wait are signed in one go, and the others are left alone" do
    with_open_vault do
      create_and_unlock
      waiting = submitted_passport
      done = submitted_passport(label: "Batch B", serial: "000322")
      done.update_columns(signature_state: "signed")
      held = submitted_passport(label: "Batch C", serial: "000323")
      held.update_columns(custodian_collection_id: "4")
      asked = []

      get passports_path
      assert_select "form[action=?]", sign_all_passports_path

      signing(->(dpp_id:, **) { asked << dpp_id; signed }) { post sign_all_passports_path }

      assert_equal [ waiting.dpp_id ], asked
      assert waiting.reload.signed?
      assert_equal I18n.t("passports.signature.all_done", signed: 1, count: 1), flash[:notice]

      get passports_path
      assert_select "form[action=?]", sign_all_passports_path, count: 0
    end
  end

  test "signing all names the passports that were not signed" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport
      failed = DppService::OperatorSigning::Outcome.new(ok: false, warnings: [], problems: [ "refused" ])

      signing(->(**) { failed }) { post sign_all_passports_path }

      assert_equal I18n.t("passports.signature.all_done", signed: 0, count: 1), flash[:notice]
      assert_equal I18n.t("passports.signature.all_failed", labels: passport.label), flash[:alert]
    end
  end

  private

  def signing(call, &block)
    stubbing(DppService::OperatorSigning, :call, call, &block)
  end

  def signed(warnings: [])
    DppService::OperatorSigning::Outcome.new(ok: true, state: "signed", warnings: warnings, problems: [], attempts: 1)
  end

  def accepted(signature_state: nil, status: 201)
    DppService::Client::Result.new(ok: true, http_status: status, problems: [], document: { "dppStatus" => "Active" },
                                   signature_state: signature_state)
  end

  def answers_hash_change = { data: '{"watt":11}' }

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

  def minted_passport(label: "Batch A", serial: "000321")
    Setting.current.update!(service_base_url: SERVICE, service_audience: SERVICE)
    Identity.first || Identity.create!(did: "did:oyd:zQmWxYzabcdefgh", origin: "minted", document_key: "k")
    passport = Passport.create!(product_type: product_type, label: label, data: '{"watt":9}',
                                unique_product_identifier: IDENTIFIER.sub("000321", serial), granularity: "item")
    stubbing(Did::Oyd, :mint_passport, ->(*, **) {
      { did: "did:oyd:zQmPassport#{passport.id}", document_key: "doc", revocation_key: "rev", revocation_log: "[]" }
    }) do
      post mint_passport_path(passport)
    end
    passport.reload
  end

  def submitted_passport(**options)
    passport = minted_passport(**options)
    submitting { post submit_passport_path(passport) }
    passport.reload
  end

  def submitting(create: ->(*, **) { accepted }, &block)
    stubbing(Soya::WebCli, :transform, ->(*) { [] }) do
      stubbing(DppService::Client, :create, create) do
        stubbing(Did::Token, :issue, ->(*, **) { "token" }, &block)
      end
    end
  end

  def correcting(update: ->(*, **) { accepted(status: 200) }, &block)
    stubbing(Soya::WebCli, :transform, ->(*) { [ { "objectType" => "DataElementCollection" } ] }) do
      stubbing(DppService::Client, :update, update) do
        stubbing(Did::Token, :issue, ->(*, **) { "token" }, &block)
      end
    end
  end
end
