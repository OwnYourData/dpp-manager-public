require "test_helper"

# Correcting a passport the service already holds.
#
# What makes this different from submitting is not the HTTP method. It is that
# the passport now exists in two places, and the application has to be able to
# say which of them is ahead — without asking the service, and without a flag
# somebody has to remember to set. That is what the fingerprint is for, and most
# of what is worth testing here.
class PassportCorrectionTest < ActionDispatch::IntegrationTest
  SERVICE = "https://dpp-service.example".freeze
  IDENTIFIER = "https://id.example.com/01/09520123456788/21/000123".freeze

  test "an edited passport says it differs, and sending the correction settles it" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport

      saving { patch passport_path(passport), params: { passport: { label: "Batch A" }, answers: { watt: 11 }.to_json } }
      assert passport.reload.differs_from_service?

      sent = nil
      correcting(update: ->(patch, **) { sent = patch; accepted }) { post correct_passport_path(passport) }

      assert_redirected_to edit_passport_path(passport)
      passport.reload
      assert_not passport.differs_from_service?, "after the service took it, the two are in step again"
      assert passport.corrected_at.present?
      assert_equal "submitted", passport.status, "correcting does not change what the passport is"

      assert_equal [ "elements", "facilityId" ], sent.keys.sort,
        "a merge patch says only what changed; the rest belongs to the service"
    end
  end

  # The identifier and the granularity are inside the published DID and cannot
  # move, so they have no business in the patch. dppStatus, lastUpdated and the
  # owner are the service's.
  test "the patch claims nothing this application does not own" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport
      saving { patch passport_path(passport), params: { passport: { label: "x" }, answers: { watt: 11 }.to_json } }

      sent = nil
      correcting(update: ->(patch, **) { sent = patch; accepted }) { post correct_passport_path(passport) }

      %w[digitalProductPassportId uniqueProductIdentifier granularity dppStatus
         lastUpdated economicOperatorId dppSchemaVersion].each do |attribute|
        assert_not sent.key?(attribute), "#{attribute} must not be in a correction"
      end
    end
  end

  test "the correction goes to where the passport was submitted, under the passport's own identifier" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport
      saving { patch passport_path(passport), params: { passport: { label: "x" }, answers: { watt: 12 }.to_json } }

      seen = nil
      correcting(update: ->(_patch, base_url:, dpp_id:, token:) {
        seen = { base_url: base_url, dpp_id: dpp_id, token: token }
        accepted
      }) { post correct_passport_path(passport) }

      assert_equal SERVICE, seen[:base_url]
      assert_equal passport.dpp_id, seen[:dpp_id]
      assert_equal "token", seen[:token]
    end
  end

  # A correction that changes nothing would still be archived by the service as a
  # new version, so the button is not offered and the action refuses.
  test "sending a correction that changes nothing is refused" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport

      get edit_passport_path(passport)
      assert_select "form[action=?]", correct_passport_path(passport), 0

      calls = 0
      correcting(update: ->(*, **) { calls += 1; accepted }) { post correct_passport_path(passport) }

      assert_equal 0, calls
      assert flash[:alert].present?
    end
  end

  test "a passport that was never submitted has nothing to correct" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport

      correcting { post correct_passport_path(passport) }

      assert flash[:alert].present?
      assert_nil passport.reload.corrected_at
    end
  end

  # The service's refusal is the service's own sentence, and the local copy stays
  # ahead: the operator can change it again and try once more.
  test "a refused correction leaves the passport marked as differing" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport
      saving { patch passport_path(passport), params: { passport: { label: "x" }, answers: { watt: 13 }.to_json } }

      refusal = DppService::Client::Result.new(ok: false, http_status: 403, problems: [ "not the owner" ])
      correcting(update: ->(*, **) { refusal }) { post correct_passport_path(passport) }

      assert_match "not the owner", flash[:alert]
      assert passport.reload.differs_from_service?
      assert_nil passport.corrected_at
      assert Event.where(kind: "passport_update_failed").exists?
    end
  end

  # Two hashes that say the same thing in a different order are the same
  # passport. A fingerprint that disagreed would offer to correct something
  # nobody changed.
  test "the fingerprint does not depend on the order the answers arrived in" do
    with_open_vault do
      passport = Passport.new(product_type: product_type, label: "x")
      passport.values = { "b" => 2, "a" => 1 }
      one = passport.input_digest

      passport.values = { "a" => 1, "b" => 2 }
      assert_equal one, passport.input_digest
    end
  end

  test "the facility counts as part of what was sent" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport

      saving do
        patch passport_path(passport), params: {
          passport: { label: "x", facility_id: "https://id.example.com/414/9520123456788" },
          answers: passport.values.to_json
        }
      end

      assert passport.reload.differs_from_service?
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
      transformation_jsonld: '{"@graph":[]}', transformation_fetched_at: Time.current
    )
  end

  def minted_passport
    Setting.current.update!(service_base_url: SERVICE, service_audience: SERVICE)
    Identity.first || Identity.create!(did: "did:oyd:zQmWxYzabcdefgh", origin: "minted", document_key: "k")
    passport = Passport.create!(product_type: product_type, label: "Batch A", data: '{"watt":9}',
                                unique_product_identifier: IDENTIFIER, granularity: "item")

    stubbing(Did::Oyd, :mint_passport, ->(*, **) {
      { did: "did:oyd:zQmPassport#{passport.id}", document_key: "doc", revocation_key: "rev", revocation_log: "[]" }
    }) { post mint_passport_path(passport) }

    passport.reload
  end

  def submitted_passport
    passport = minted_passport
    stubbing(Soya::WebCli, :transform, ->(*) { [] }) do
      stubbing(DppService::Client, :create, ->(*, **) { accepted }) do
        stubbing(Did::Token, :issue, ->(*, **) { "token" }) { post submit_passport_path(passport) }
      end
    end
    passport.reload
  end

  def accepted
    DppService::Client::Result.new(ok: true, http_status: 200, problems: [], document: { "dppStatus" => "Active" })
  end

  def correcting(update: ->(*, **) { accepted }, &block)
    stubbing(Soya::WebCli, :transform, ->(*) { [ { "objectType" => "DataElementCollection" } ] }) do
      stubbing(DppService::Client, :update, update) do
        stubbing(Did::Token, :issue, ->(*, **) { "token" }, &block)
      end
    end
  end

  # Saving a passport asks soya-web-cli to check it, which is not running here.
  def saving(&block) = stubbing(Soya::Validation, :check, ->(*) { nil }, &block)
end
