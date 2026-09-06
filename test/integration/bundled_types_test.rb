require "test_helper"

# The way back for a vault that existed before these structures shipped.
#
# A new vault gets them when it is created; an old one is offered them, once,
# and only while something is actually missing. Doing it on every unlock instead
# would put back a type the operator deleted, which is an application arguing
# with a decision somebody made.
class BundledTypesTest < ActionDispatch::IntegrationTest
  FORM = { "schema" => { "properties" => { "watt" => { "type" => "integer" } } }, "ui" => {} }.freeze

  test "the offer appears while something is missing and goes away once it is not" do
    with_open_vault do
      create_and_unlock

      get product_types_path
      assert_select "form[action=?]", install_bundled_product_types_path, 1

      offline { post install_bundled_product_types_path }

      get product_types_path
      assert_select "form[action=?]", install_bundled_product_types_path, 0
    end
  end

  test "installing adds the type with its transformation and says which" do
    with_open_vault do
      create_and_unlock

      offline { post install_bundled_product_types_path }

      assert_redirected_to product_types_path
      type = ProductType.find_by(structure_name: "DppLedLamp")
      assert type.fetched?
      assert type.transformation_fetched?
      assert type.readable?, "the image carries the way back as well, so a foreign passport can be read offline"
      assert_match type.label, flash[:notice]
    end
  end

  test "asking again when everything is there says so instead of pretending" do
    with_open_vault do
      create_and_unlock
      offline { post install_bundled_product_types_path }

      offline { post install_bundled_product_types_path }

      assert flash[:alert].present?
      assert_equal 1, ProductType.where(structure_name: "DppLedLamp").count
    end
  end

  private

  def offline(&block)
    stubbing(Soya::Repository, :fetch, ->(*) { raise Soya::Error, "unreachable" }) do
      stubbing(Soya::WebCli, :form, ->(*, **) { FORM }, &block)
    end
  end
end
