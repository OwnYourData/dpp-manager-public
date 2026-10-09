require "test_helper"

# The legal configuration of a product type (ESPR Art. 9): entered on the
# product type's page, shown in the list, and felt when a passport is started.
class ProductTypeConfigurationTest < ActionDispatch::IntegrationTest
  FORM = { "en" => { "schema" => { "properties" => { "watt" => { "type" => "integer" } } }, "ui" => {} } }.freeze

  test "the configuration is saved with the type, counted, and shown in the list" do
    with_open_vault do
      create_and_unlock
      type = create_type

      patch product_type_path(type), params: { product_type: {
        label: type.label, structure_name: type.structure_name, repo_base_url: type.repo_base_url,
        legal_act: "Regulation (EU) 2023/1542", legal_act_url: "https://eur-lex.europa.eu/eli/reg/2023/1542/oj",
        legal_act_valid_from: "2023-08-17", dpp_required_from: "2027-02-18", granularity: "item",
        carriers: [ "", "qr", "datamatrix" ], carrier_placement: [ "", "product" ],
        carrier_layout: "ISO/IEC 18004, at least 10 mm", availability_years: "10"
      } }

      assert_redirected_to product_types_path
      type.reload
      assert_equal 1, type.config_version
      assert_equal %w[qr datamatrix], type.carriers
      assert_equal %w[product], type.carrier_placement
      assert_equal Date.new(2027, 2, 18), type.dpp_required_from
      assert_equal 10, type.availability_years
      assert_not_nil type.fetched_at, "a change of configuration must not throw away the fetched structure"

      get product_types_path
      assert_match "Regulation (EU) 2023/1542", response.body
      assert_match I18n.t("product_types.configuration.version", version: 1), response.body
    end
  end

  test "an impossible configuration is refused with the form shown again" do
    with_open_vault do
      create_and_unlock
      type = create_type

      patch product_type_path(type), params: { product_type: {
        label: type.label, structure_name: type.structure_name, repo_base_url: type.repo_base_url,
        availability_years: "0", carriers: [ "barcode" ]
      } }

      assert_response :unprocessable_entity
      assert_equal 0, type.reload.config_version
    end
  end

  test "a new passport starts with the granularity the type prescribes" do
    with_open_vault do
      create_and_unlock
      type = create_type(granularity: "batch")

      get new_passport_path(product_type_id: type.id)
      assert_response :success
      assert_select "select#passport_granularity option[selected][value=?]", "batch"
    end
  end

  private

  def create_type(**overrides)
    ProductType.create!({ label: "Lamp", structure_name: "Lamp", repo_base_url: "https://soya.example",
                          jsonld: '{"@graph":[]}', forms: FORM.to_json, fetched_at: Time.current }.merge(overrides))
  end
end
