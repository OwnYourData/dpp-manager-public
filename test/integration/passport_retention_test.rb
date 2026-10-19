require "test_helper"

# How long a passport has to stay available (ESPR Art. 9(2)(i)), and what it
# was issued under (CFG-011).
#
# The period is worked out at submission from the day the product was placed
# on the market and the years its product type prescribes, sent to the
# service, and kept with the passport together with a snapshot of the product
# type's configuration. Ending the passport before the period is over is
# refused here before the service is asked, which would refuse it as well.
class PassportRetentionTest < ActionDispatch::IntegrationTest
  SERVICE = "https://dpp-service.example".freeze
  IDENTIFIER = "https://id.example.com/01/09520123456788/21/000123".freeze

  test "the period runs from the day the product was placed on the market" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport(years: 10, placed_on_market_on: Date.new(2027, 3, 1))

      sent = :not_called
      submitting(create: ->(*, retain_until: nil, **) { sent = retain_until; accepted }) do
        post submit_passport_path(passport)
      end

      assert_equal Date.new(2037, 3, 1), sent
      assert_equal Date.new(2037, 3, 1), passport.reload.retain_until
    end
  end

  test "without that day the period runs from the submission" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport(years: 15)

      # Today and not a travelled-to date: moving the clock trips the idle lock,
      # and the vault closes under the test.
      submitting { post submit_passport_path(passport) }

      assert_equal Date.current.advance(years: 15), passport.reload.retain_until
    end
  end

  test "a product type without a period sends none and records none" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport(years: nil)

      sent = :not_called
      submitting(create: ->(*, retain_until: nil, **) { sent = retain_until; accepted }) do
        post submit_passport_path(passport)
      end

      assert_nil sent
      assert_nil passport.reload.retain_until
    end
  end

  # After submission the hint under the date says what the date did, and
  # nothing about a period where none applies.
  test "after submission a given date is named as where the period was worked out from" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport(years: 10, placed_on_market_on: Date.new(2027, 3, 1))
      submitting { post submit_passport_path(passport) }

      get edit_passport_path(passport)
      assert_select "p.hint", text: I18n.t("passports.envelope.placed_on_market_fixed")
    end
  end

  test "after submission an empty date says the period started on the day of submission, and which" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport(years: 15)
      submitting { post submit_passport_path(passport) }

      get edit_passport_path(passport)
      day = I18n.l(passport.reload.submitted_at.utc.to_date)
      assert_select "p.hint", text: I18n.t("passports.envelope.placed_on_market_from_submission", date: day)
      assert_select "p.hint", text: I18n.t("passports.envelope.placed_on_market_fixed"), count: 0
    end
  end

  test "after submission without a period the hint does not claim one" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport(years: nil)
      submitting { post submit_passport_path(passport) }

      get edit_passport_path(passport)
      assert_select "p.hint", text: I18n.t("passports.envelope.placed_on_market_no_period")
      assert_select "p.hint", text: I18n.t("passports.envelope.placed_on_market_fixed"), count: 0
    end
  end

  test "the passport keeps the configuration it was issued under, even when the type changes later" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport(years: 10)

      submitting { post submit_passport_path(passport) }
      passport.product_type.update!(legal_act: "Something else", availability_years: 20)

      snapshot = passport.reload.configuration_snapshot_hash
      assert_equal "Regulation (EU) 2023/1542", snapshot["legal_act"]
      assert_equal 10, snapshot["availability_years"]
      assert_equal 1, snapshot["config_version"]
      assert_equal "DppBattery", snapshot.dig("structure", "name")
      assert snapshot.dig("structure", "fetched_at"), "the version of the structure is part of what it was issued under"
    end
  end

  test "the day of placing on the market is fixed once the passport is submitted" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport(years: 10, placed_on_market_on: Date.new(2027, 3, 1))
      submitting { post submit_passport_path(passport) }

      passport.reload.placed_on_market_on = Date.new(2028, 1, 1)
      assert_not passport.valid?
      assert passport.errors[:placed_on_market_on].any?
    end
  end

  test "a passport inside its period is not ended, and the service is not even asked" do
    with_open_vault do
      create_and_unlock
      passport = minted_passport(years: 10)
      submitting { post submit_passport_path(passport) }

      called = false
      stubbing(DppService::Client, :delete, ->(*, **) { called = true; accepted }) do
        stubbing(Did::Token, :issue, ->(*, **) { "token" }) { post retire_passport_path(passport) }
      end

      assert_not called
      assert_not passport.reload.retired?
      assert_equal I18n.t("passports.retire.retained", date: I18n.l(passport.retain_until)), flash[:alert]
    end
  end

  test "the last day belongs to the period, as it does at the service" do
    with_open_vault do
      passport = Passport.new(retain_until: Date.new(2037, 3, 1))

      assert passport.retained_on?(Date.new(2037, 3, 1))
      assert_not passport.retained_on?(Date.new(2037, 3, 2))
    end
  end

  private

  def product_type(years)
    ProductType.create!(
      label: "Battery", structure_name: "DppBattery", repo_base_url: "https://soya.example",
      jsonld: '{"@graph":[]}',
      forms: { "en" => { "schema" => { "properties" => { "watt" => { "type" => "integer" } } }, "ui" => {} } }.to_json,
      fetched_at: Time.current,
      transformation_name: "DppBatteryToEN18223",
      transformation_jsonld: '{"@graph":[]}', transformation_fetched_at: Time.current,
      legal_act: "Regulation (EU) 2023/1542", availability_years: years
    )
  end

  def minted_passport(years:, placed_on_market_on: nil)
    Setting.current.update!(service_base_url: SERVICE, service_audience: SERVICE)
    Identity.first || Identity.create!(did: "did:oyd:zQmWxYzabcdefgh", origin: "minted", document_key: "k")
    passport = Passport.create!(product_type: product_type(years), label: "Battery A", data: '{"watt":9}',
                                unique_product_identifier: IDENTIFIER, granularity: "item",
                                placed_on_market_on: placed_on_market_on)
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

  def submitting(create: ->(*, **) { accepted }, &block)
    stubbing(Soya::Validation, :check, ->(*) { nil }) do
      stubbing(Soya::WebCli, :transform, ->(*) { [] }) do
        stubbing(DppService::Client, :create, create) do
          stubbing(Did::Token, :issue, ->(*, **) { "token" }, &block)
        end
      end
    end
  end
end
