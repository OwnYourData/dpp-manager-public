require "test_helper"

# A passport of a type whose access classes are switched on: it names the
# type's access policy when it is created and corrected, the service's report
# on the fit is shown, and a passport already at the service is moved to a
# newer version of the policy without its content being sent again.
class PassportAccessPolicyTest < ActionDispatch::IntegrationTest
  SERVICE = "https://dpp-service.example".freeze
  IDENTIFIER = "https://id.example.com/01/09520123456788/21/000123".freeze
  DID = "did:oyd:zQmWxYzabcdefgh".freeze
  POLICY_1 = "#{DID}/access-policies/DppLedLamp/1".freeze
  POLICY_2 = "#{DID}/access-policies/DppLedLamp/2".freeze

  test "a passport of a type with access classes is created naming its policy, registered first" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport
      order = []
      sent = nil

      writing(register: ->(policy, **) { order << [ :register, policy["id"] ]; registered },
              create: lambda { |document, **kwargs|
                order << [ :create, kwargs[:access_policy] ]
                sent = kwargs
                accepted(report: report(POLICY_1, 2, 1))
              }) do
        post submit_passport_path(passport)
      end

      assert_equal [ [ :register, POLICY_1 ], [ :create, POLICY_1 ] ], order
      assert_equal POLICY_1, sent[:access_policy]

      passport.reload
      assert passport.submitted?
      assert_equal POLICY_1, passport.access_policy_id
      assert_equal 2, passport.access_policy_report_hash["unclassified"]
      assert_equal 1, passport.access_policy_report_hash["unusedRules"]
      assert_match I18n.t("passports.access_policy.report", unclassified: 2, unused: 1), flash[:notice]
    end
  end

  # A passport that names a policy the service refused must not go out public
  # instead: nothing is sent at all.
  test "when the service does not take the policy, the passport is not sent" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport
      created = false
      refusal = DppService::Client::Result.new(ok: false, http_status: 400, problems: [ "not a valid policy" ])

      writing(register: ->(*, **) { refusal }, create: ->(*, **) { created = true; accepted }) do
        post submit_passport_path(passport)
      end

      assert_not created
      assert_not passport.reload.submitted?
      assert_match "not a valid policy", flash[:alert]
    end
  end

  test "a type with its access classes switched off sends nothing about access" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport
      passport.product_type.update!(access_policy_enabled: false)
      registered_any = false
      sent = nil

      writing(register: ->(*, **) { registered_any = true; registered },
              create: ->(_document, **kwargs) { sent = kwargs; accepted }) do
        post submit_passport_path(passport)
      end

      assert_not registered_any
      assert_not sent.key?(:access_policy)
      assert_nil passport.reload.access_policy_id
    end
  end

  test "a correction carries the type's current policy along" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport
      passport.update!(data: '{"watt":10}')
      passport.product_type.update!(access_policy_version: 2)
      sent = nil

      writing(update: ->(_patch, **kwargs) { sent = kwargs; accepted(report: report(POLICY_2, 0, 0)) }) do
        post correct_passport_path(passport)
      end

      assert_equal POLICY_2, sent[:access_policy]
      assert_equal POLICY_2, passport.reload.access_policy_id
    end
  end

  test "the page offers the newer policy, and applying it sends nothing but the policy" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport
      passport.product_type.update!(access_policy_version: 2)
      passport.update!(data: '{"watt":11}')

      get edit_passport_path(passport)
      assert_select "form[action=?]", apply_access_policy_passport_path(passport)

      sent = nil
      writing(update: ->(patch, **kwargs) { sent = [ patch, kwargs ]; accepted(report: report(POLICY_2, 0, 3)) }) do
        post apply_access_policy_passport_path(passport)
      end

      patch, kwargs = sent
      assert_equal({}, patch, "the half-edited answers stay here")
      assert_equal POLICY_2, kwargs[:access_policy]
      passport.reload
      assert_equal POLICY_2, passport.access_policy_id
      assert passport.differs_from_service?, "the edit is still waiting to be sent as a correction"
      assert Event.where(kind: "passport_access_policy_applied").exists?

      get edit_passport_path(passport)
      assert_select "form[action=?]", apply_access_policy_passport_path(passport), 0
    end
  end

  # The classification changes the public part, so the payload the custodian
  # delivers changes too; it is attested again as after any write.
  test "applying a policy attests the payload again" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport
      passport.product_type.update!(access_policy_version: 2)
      attested = nil
      answer = accepted(report: report(POLICY_2, 0, 0))
      answer.commitment = DppService::Client::Commitment.new(payload_hash: "zQmNew", state: "pending")

      writing(update: ->(*, **) { answer }) do
        stubbing(Did::Oyd, :commit_payload, ->(_did, payload_hash:, **) { attested = payload_hash; { revocation_log: "[]" } }) do
          post apply_access_policy_passport_path(passport)
        end
      end

      assert_equal "zQmNew", attested
      assert passport.reload.payload_attested?
    end
  end

  test "a refusal while applying is shown and changes nothing here" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport
      passport.product_type.update!(access_policy_version: 2)
      refusal = DppService::Client::Result.new(ok: false, http_status: 400, problems: [ "cannot classify" ])

      writing(update: ->(*, **) { refusal }) { post apply_access_policy_passport_path(passport) }

      assert_equal POLICY_1, passport.reload.access_policy_id
      assert_match "cannot classify", flash[:alert]
      assert Event.where(kind: "passport_access_policy_failed").exists?
    end
  end

  test "nothing is applied to a passport the service does not hold" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport
      called = false

      writing(update: ->(*, **) { called = true; accepted }) { post apply_access_policy_passport_path(passport) }

      assert_not called
      assert_equal I18n.t("passports.access_policy.not_submitted"), flash[:alert]
    end
  end

  test "the lists behind the counts are shown as the service has them" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport
      details = DppService::Client::Result.new(ok: true, http_status: 200, problems: [], document: {
        "policy" => POLICY_1, "unclassified" => [ "Extra/Computed" ], "unusedRules" => [ "Durability/RatedLifetime" ]
      })

      stubbing(Did::Token, :issue, ->(*, **) { "token" }) do
        stubbing(DppService::Client, :read_access_policy, ->(base_url:, dpp_id:, token:) { details }) do
          get access_policy_passport_path(passport)
        end
      end

      assert_response :success
      assert_select "code", "Extra/Computed"
      assert_select "code", "Durability/RatedLifetime"
    end
  end

  private

  def product_type
    @product_type ||= ProductType.create!(
      label: "Lamp", structure_name: "DppLedLamp", repo_base_url: "https://soya.example",
      jsonld: '{"@graph":[]}',
      forms: { "en" => { "schema" => { "properties" => { "watt" => { "type" => "integer" } } }, "ui" => {} } }.to_json,
      fetched_at: Time.current,
      transformation_name: "DppLedLampToEN18223",
      transformation_jsonld: '{"@graph":[]}', transformation_fetched_at: Time.current,
      access_policy_enabled: true, access_policy_version: 1,
      access_classes: JSON.generate("ProductIdentification/SerialNumber" => "legitimateInterest")
    )
  end

  def ready_passport
    Setting.current.update!(service_base_url: SERVICE, service_audience: SERVICE)
    Identity.first || Identity.create!(did: DID, origin: "minted", document_key: "k")
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

  def submitted_passport
    passport = minted_passport
    writing(create: ->(*, **) { accepted(report: report(POLICY_1, 0, 0)) }) { post submit_passport_path(passport) }
    passport.reload.tap { |p| assert_equal POLICY_1, p.access_policy_id }
  end

  def report(id, unclassified, unused)
    DppService::Client::AccessPolicyReport.new(id: id, unclassified: unclassified, unused_rules: unused)
  end

  def accepted(report: nil)
    DppService::Client::Result.new(ok: true, http_status: 201, problems: [],
                                   document: { "dppStatus" => "Active" }, access_policy: report)
  end

  def registered
    DppService::Client::Result.new(ok: true, http_status: 200, problems: [], document: {})
  end

  # Everything that would leave this machine, replaced together.
  def writing(register: ->(*, **) { registered }, create: ->(*, **) { accepted }, update: ->(*, **) { accepted },
              &block)
    stubbing(Soya::WebCli, :transform, ->(*) { [] }) do
      stubbing(Did::Token, :issue, ->(*, **) { "token" }) do
        stubbing(DppService::Client, :register_access_policy, register) do
          stubbing(DppService::Client, :create, create) do
            stubbing(DppService::Client, :update, update, &block)
          end
        end
      end
    end
  end
end
