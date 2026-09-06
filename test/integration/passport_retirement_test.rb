require "test_helper"

# Ending a passport.
#
# Two acts against two systems, and the whole of what is worth testing here is
# what happens when only one of them succeeds. The service can be asked again;
# the revocation cannot be asked of anybody else, because only this machine
# holds the key. So the order is fixed — withdraw first, revoke second — and the
# row has to be able to say which half is done.
class PassportRetirementTest < ActionDispatch::IntegrationTest
  SERVICE = "https://dpp-service.example".freeze
  IDENTIFIER = "https://id.example.com/01/09520123456788/21/000123".freeze

  test "ending a submitted passport withdraws it and then revokes its identifier" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport

      order = []
      retiring(delete: ->(*, **) { order << :delete; accepted },
               revoke: ->(*, **) { order << :revoke; true }) { post retire_passport_path(passport) }

      assert_equal [ :delete, :revoke ], order,
        "the service stops serving it before the identifier stops resolving"

      passport.reload
      assert_equal "retired", passport.status
      assert passport.retired?
      assert passport.revoked?
      assert_not passport.half_retired?
      assert_equal I18n.t("passports.retire.done"), flash[:notice]
      assert Event.where(kind: "passport_retired").exists?
      assert Event.where(kind: "passport_revoked").exists?
    end
  end

  # An ended passport keeps every record it had, so unless the page says
  # otherwise it looks exactly like a live one — and offers a correction the
  # service would refuse. The state has to be visible before the actions are.
  test "an ended passport says so, and offers nothing that would be refused" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport
      retiring { post retire_passport_path(passport) }

      get edit_passport_path(passport)
      assert_response :success
      assert_select "div.warning.ended", text: /#{Regexp.escape(I18n.t('passports.retired.title'))}/
      assert_select "form[action=?]", correct_passport_path(passport), count: 0
      assert_select "form[action=?]", retire_passport_path(passport), count: 0

      get passports_path
      assert_select "span.ended", text: I18n.t("passports.retired.badge")
    end
  end

  # Half ended is a different sentence: the service has let go, the identifier
  # has not, and the page must not call that finished.
  test "a half ended passport is not described as ended" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport
      retiring(revoke: ->(*, **) { raise Did::Oyd::Error, "registry unreachable" }) do
        post retire_passport_path(passport)
      end

      half = I18n.t("passports.retired.half_body", when: "X").split(". ", 2).last

      get edit_passport_path(passport)
      assert_select "div.warning.ended", text: /#{Regexp.escape(half)}/
      assert_select "form[action=?]", retire_passport_path(passport)
    end
  end

  test "the withdrawal goes to where the passport was submitted, under its own identifier" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport

      seen = nil
      retiring(delete: ->(base_url:, dpp_id:, token:) {
        seen = { base_url: base_url, dpp_id: dpp_id, token: token }
        accepted
      }) { post retire_passport_path(passport) }

      assert_equal SERVICE, seen[:base_url]
      assert_equal passport.dpp_id, seen[:dpp_id]
      assert_equal "token", seen[:token]
    end
  end

  # The service refusing is the one failure with a way back: nothing has
  # happened yet, and the identifier must stay live so that what the service
  # still serves keeps resolving.
  test "a refused withdrawal leaves the passport exactly as it was" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport

      revocations = 0
      refusal = DppService::Client::Result.new(ok: false, http_status: 403, problems: [ "not the owner" ])
      retiring(delete: ->(*, **) { refusal },
               revoke: ->(*, **) { revocations += 1; true }) { post retire_passport_path(passport) }

      assert_equal 0, revocations, "the identifier is not revoked while the service still serves the passport"
      assert_match "not the owner", flash[:alert]

      passport.reload
      assert_not passport.retired?
      assert_not passport.revoked?
      assert_equal "submitted", passport.status
      assert Event.where(kind: "passport_retire_failed").exists?
    end
  end

  test "a service that cannot be reached leaves the passport as it was" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport

      retiring(delete: ->(*, **) { raise DppService::Client::Error, "unreachable" }) do
        post retire_passport_path(passport)
      end

      assert flash[:alert].present?
      assert_not passport.reload.retired?
    end
  end

  # The half that has no second owner. The passport is out of the service's
  # hands and the identifier is still live — unfinished rather than wrong, and
  # the page has to say so instead of calling the passport ended.
  test "a failed revocation leaves the passport half ended, and the page offers to finish" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport

      retiring(revoke: ->(*, **) { raise Did::Oyd::Error, "the registry did not answer" }) do
        post retire_passport_path(passport)
      end

      passport.reload
      assert passport.retired?
      assert_not passport.revoked?
      assert passport.half_retired?
      assert_match "the registry did not answer", flash[:alert]
      assert Event.where(kind: "passport_revoke_failed").exists?

      get edit_passport_path(passport)
      assert_select ".danger-zone button", text: I18n.t("passports.retire.finish")
      assert_select ".danger-zone button", { text: I18n.t("passports.remove.button"), count: 0 },
        "a passport whose identifier is still live is not offered for deletion"
    end
  end

  test "finishing a half ended passport revokes without asking the service again" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport
      retiring(revoke: ->(*, **) { raise Did::Oyd::Error, "later" }) { post retire_passport_path(passport) }

      deletions = 0
      retiring(delete: ->(*, **) { deletions += 1; accepted }) { post retire_passport_path(passport) }

      assert_equal 0, deletions, "the service has already let go of it"
      assert passport.reload.revoked?
      assert_equal I18n.t("passports.retire.done"), flash[:notice]
    end
  end

  # Minted but never handed to anyone. There is nothing at a service to
  # withdraw; the identifier is the only thing out in the world.
  test "a minted passport that was never submitted is only revoked" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport

      deletions = 0
      retiring(delete: ->(*, **) { deletions += 1; accepted }) { post retire_passport_path(passport) }

      assert_equal 0, deletions
      passport.reload
      assert_equal "retired", passport.status
      assert passport.revoked?
    end
  end

  test "a passport without an identifier has nothing to end" do
    with_open_vault do
      create_and_unlock
      passport = Passport.create!(product_type: product_type, label: "Draft",
                                  unique_product_identifier: IDENTIFIER, granularity: "item")

      retiring { post retire_passport_path(passport) }

      assert_equal I18n.t("passports.retire.not_minted"), flash[:alert]
      assert_not passport.reload.retired?
    end
  end

  test "an already ended passport is not ended twice" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport
      retiring { post retire_passport_path(passport) }

      calls = 0
      retiring(delete: ->(*, **) { calls += 1; accepted }, revoke: ->(*, **) { calls += 1; true }) do
        post retire_passport_path(passport)
      end

      assert_equal 0, calls
      assert_equal I18n.t("passports.retire.already"), flash[:alert]
    end
  end

  # Deleting the row takes the keys with it, and without the revocation key the
  # identifier can never be ended. So the row may only go once its keys are
  # spent.
  test "a minted passport can only be deleted once its identifier is revoked" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport

      delete passport_path(passport)
      assert_equal I18n.t("passports.remove.minted"), flash[:alert]
      assert Passport.exists?(passport.id)

      retiring { post retire_passport_path(passport) }

      delete passport_path(passport)
      assert_redirected_to passports_path
      assert_not Passport.exists?(passport.id)
    end
  end

  test "the missing revocation key is said rather than swallowed" do
    with_open_vault do
      create_and_unlock
      passport = submitted_passport
      passport.passport_key.update!(revocation_key: "")

      retiring { post retire_passport_path(passport) }

      assert_equal I18n.t("passports.retire.no_keys"), flash[:alert]
      assert passport.reload.half_retired?
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
    DppService::Client::Result.new(ok: true, http_status: 204, problems: [], document: nil)
  end

  def retiring(delete: ->(*, **) { accepted }, revoke: ->(*, **) { true }, &block)
    stubbing(DppService::Client, :delete, delete) do
      stubbing(Did::Oyd, :revoke, revoke) do
        stubbing(Did::Token, :issue, ->(*, **) { "token" }, &block)
      end
    end
  end
end
