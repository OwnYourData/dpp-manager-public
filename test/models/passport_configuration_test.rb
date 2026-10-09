require "test_helper"

# A passport measured against its product type's legal configuration. The
# result joins the structure's own problems, so the same second click that
# sends a passport the structure objects to also sends one the configuration
# objects to.
class PassportConfigurationTest < ActiveSupport::TestCase
  VALID_REPORT = { "isValid" => true, "results" => [] }.freeze

  test "a passport that follows the prescribed granularity has nothing to report" do
    with_open_vault do
      assert_empty passport(prescribed: "item", chosen: "item").configuration_problems
      assert_empty passport(prescribed: nil, chosen: "model").configuration_problems
      assert_empty passport(prescribed: "item", chosen: nil).configuration_problems
    end
  end

  test "a passport that differs from the prescribed granularity says so in words" do
    with_open_vault do
      problems = passport(prescribed: "batch", chosen: "item").configuration_problems

      assert_equal 1, problems.size
      assert_includes problems.first, I18n.t("passports.granularities.batch")
    end
  end

  test "the check holds a passport back even when the structure is satisfied" do
    with_open_vault do
      subject = passport(prescribed: "batch", chosen: "item")

      stubbing(Soya::WebCli, :acquire, ->(*) { {} }) do
        stubbing(Soya::WebCli, :validate, ->(*) { VALID_REPORT }) do
          result = Soya::Validation.check(subject)

          assert_not result.valid?
          assert_equal subject.configuration_problems, result.problems
        end
      end
    end
  end

  private

  def passport(prescribed:, chosen:)
    type = ProductType.create!(label: "Lamp #{SecureRandom.hex(3)}", structure_name: "Lamp#{SecureRandom.hex(3)}",
                               repo_base_url: "https://soya.example", jsonld: '{"@graph":[]}',
                               forms: { "en" => { "schema" => { "properties" => {} }, "ui" => {} } }.to_json,
                               fetched_at: Time.current, granularity: prescribed)
    Passport.new(product_type: type, label: "A", granularity: chosen)
  end
end
