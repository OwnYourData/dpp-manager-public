require "test_helper"

# A passport without a custodian stays in the DPP Service's own database, and
# someone who scans the product reaches it only if the identifier is on a host
# the service answers on. The service names those hosts in its discovery
# document (carrierHosts); the form starts there, and the page says when an
# identifier is elsewhere.
class PassportCarrierHostTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  SERVICE = "https://dpp-service.example".freeze
  FORM = { "en" => { "schema" => { "properties" => {} }, "ui" => {} } }.freeze

  test "a new passport starts on the first host the service answers on, and the hint says why" do
    with_open_vault do
      create_and_unlock
      configure_service
      type = create_type

      asked = []
      stubbing(DppService::Directory, :carrier_hosts, ->(base) { asked << base; %w[id.example.org own.example] }) do
        get new_passport_path(product_type_id: type.id)
      end

      assert_response :success
      assert_equal [ SERVICE ], asked
      assert_select "input#passport_unique_product_identifier[value=?]", "https://id.example.org/01/"
      assert_select "p.hint", text: /id\.example\.org/
      assert_equal %w[id.example.org own.example], Setting.current.carrier_hosts
    end
  end

  test "the hosts are asked for once in a while, not on every new passport" do
    with_open_vault do
      create_and_unlock
      configure_service
      type = create_type

      calls = 0
      stubbing(DppService::Directory, :carrier_hosts, ->(_base) { calls += 1; %w[id.example.org] }) do
        get new_passport_path(product_type_id: type.id)
        get new_passport_path(product_type_id: type.id)
        travel(Setting::CARRIER_HOSTS_FOR + 1.minute) { get new_passport_path(product_type_id: type.id) }
      end

      assert_equal 2, calls
    end
  end

  test "a service out of reach leaves the list as it was" do
    with_open_vault do
      create_and_unlock
      configure_service
      Setting.current.update!(service_carrier_hosts: '["id.example.org"]', service_carrier_hosts_at: 1.day.ago)
      type = create_type

      stubbing(DppService::Directory, :carrier_hosts, ->(_base) { nil }) do
        get new_passport_path(product_type_id: type.id)
      end

      assert_select "input#passport_unique_product_identifier[value=?]", "https://id.example.org/01/"
      assert_equal %w[id.example.org], Setting.current.carrier_hosts
      assert_not Setting.current.carrier_hosts_due?, "the failed attempt has to count, or every page tries again"
    end
  end

  test "with a custodian nothing is suggested: the custodian answers for its passports" do
    with_open_vault do
      create_and_unlock
      configure_service
      Setting.current.update!(custodian_base_url: "https://pod.example", custodian_collection_id: "7")
      type = create_type

      stubbing(DppService::Directory, :carrier_hosts, ->(_base) { %w[id.example.org] }) do
        get new_passport_path(product_type_id: type.id)
      end

      assert_select "input#passport_unique_product_identifier" do |input|
        assert_nil input.first["value"]
      end
    end
  end

  test "the suggestion left as it was is saved as no identifier, so the draft is not refused for it" do
    with_open_vault do
      create_and_unlock
      configure_service
      Setting.current.record_carrier_hosts!(%w[id.example.org])
      type = create_type

      without_validation do
        post passports_path, params: { product_type_id: type.id, answers: "{}",
                                       passport: { label: "Draft", unique_product_identifier: "https://id.example.org/01/" } }
      end

      assert_redirected_to edit_passport_path(Passport.last)
      assert_equal "", Passport.last.unique_product_identifier
    end
  end

  test "an identifier on a host the service does not answer on is warned about, one on its host is not" do
    with_open_vault do
      create_and_unlock
      configure_service
      Setting.current.record_carrier_hosts!(%w[id.example.org])
      type = create_type

      elsewhere = Passport.create!(product_type: type, label: "Elsewhere", granularity: "item",
                                   unique_product_identifier: "https://p.lumina.example/01/09520123456788/21/0001")
      get edit_passport_path(elsewhere)
      assert_select "p.warning-inline", text: /p\.lumina\.example/

      served = Passport.create!(product_type: type, label: "Served", granularity: "item",
                                unique_product_identifier: "https://ID.example.org/01/09520123456788/21/0002")
      get edit_passport_path(served)
      assert_select "p.warning-inline", { text: /id\.example\.org/, count: 0 }
    end
  end

  test "nothing is warned about with a custodian, or when the service names no host" do
    with_open_vault do
      create_and_unlock
      configure_service
      type = create_type
      passport = Passport.create!(product_type: type, label: "Elsewhere", granularity: "item",
                                  unique_product_identifier: "https://p.lumina.example/01/09520123456788/21/0001")

      Setting.current.record_carrier_hosts!([])
      get edit_passport_path(passport)
      assert_select "p.warning-inline", { text: /p\.lumina\.example/, count: 0 }

      Setting.current.record_carrier_hosts!(%w[id.example.org])
      Setting.current.update!(custodian_base_url: "https://pod.example", custodian_collection_id: "7")
      get edit_passport_path(passport)
      assert_select "p.warning-inline", { text: /p\.lumina\.example/, count: 0 }
    end
  end

  test "German says the same" do
    with_open_vault do
      create_and_unlock
      configure_service
      Setting.current.update!(locale: "de")
      Setting.current.record_carrier_hosts!(%w[id.example.org])
      type = create_type
      passport = Passport.create!(product_type: type, label: "Anderswo", granularity: "item",
                                  unique_product_identifier: "https://p.lumina.example/01/09520123456788/21/0001")

      get edit_passport_path(passport)
      assert_select "p.warning-inline", text: /kommt nicht zu diesem Pass/
    end
  end

  private

  def configure_service
    Setting.current.update!(service_base_url: SERVICE, service_audience: SERVICE)
  end

  def create_type
    ProductType.create!(label: "Lamp", structure_name: "Lamp", repo_base_url: "https://soya.example",
                        jsonld: '{"@graph":[]}', forms: FORM.to_json, fetched_at: Time.current)
  end

  def without_validation(&block) = stubbing(Soya::Validation, :check, ->(*) { nil }, &block)
end
