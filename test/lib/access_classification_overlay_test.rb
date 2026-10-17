require "test_helper"

# The access classes the bundled structures suggest, in an OverlayClassification.
#
# The bundled JSON-LD is what the repository serves for the YAML beside it. If
# the two disagreed, a fresh installation would start from one set of classes
# and "Fetch again" would quietly replace it with another.
class AccessClassificationOverlayTest < ActiveSupport::TestCase
  %w[DppLedLamp DppBattery].each do |name|
    test "#{name}: the bundled structure carries the classification authored beside it" do
      overlay = authored_overlay(name)
      assert overlay, "#{name}.yaml has an OverlayClassification"

      graph = bundled(name)["@graph"]
      node = graph.find { |n| n["@type"] == "OverlayClassification" }
      assert node, "the overlay itself is in the JSON-LD"
      assert_equal overlay["name"], node["name"]

      bundled_classes = graph.select { |n| n.key?("classification") }
                             .to_h { |n| [ n["@id"], Array(n["classification"]) ] }
      assert_equal overlay["attributes"].transform_values { |v| Array(v) }, bundled_classes
    end

    test "#{name}: every suggested class is one of the vocabulary, for a field that exists" do
      fields = YAML.safe_load_file(Rails.root.join("soya/#{name}.yaml")).dig("content", "bases", 0, "attributes").keys

      authored_overlay(name)["attributes"].each do |field, value|
        assert_includes fields, field
        assert Dpp::AccessPolicy.notation(value), "#{field}: #{value} is not an access class"
      end
    end

    test "#{name}: a product type reads the suggestions out of its structure" do
      with_open_vault do
        type = ProductType.new(jsonld: Rails.root.join("soya/#{name}.jsonld").read)

        suggestions = type.access_class_suggestions
        assert_equal authored_overlay(name)["attributes"].keys.sort, suggestions.keys.sort
        assert(suggestions.values.all? { |cls| Dpp::AccessPolicy::CLASSES.include?(cls) })
      end
    end
  end

  test "the lamp keeps its serial number for readers with a legitimate interest" do
    with_open_vault do
      type = ProductType.new(jsonld: Rails.root.join("soya/DppLedLamp.jsonld").read)

      assert_equal "legitimateInterest", type.access_class_suggestions["serialNumber"]
      assert_nil type.access_class_suggestions["manufacturerName"], "public, by having no entry"
    end
  end

  # Other classifications ("pii") may share the overlay type; they are not
  # access classes and are left alone.
  test "classifications of another kind are not read as access classes" do
    with_open_vault do
      type = ProductType.new(jsonld: JSON.generate("@graph" => [
        { "@id" => "name", "classification" => [ "pii" ] },
        { "@id" => "serial", "classification" => [ "pii", "https://w3id.org/soya/dpp-access/v1#authority" ] }
      ]))

      assert_equal({ "serial" => "authority" }, type.access_class_suggestions)
    end
  end

  private

  def authored_overlay(name)
    YAML.safe_load_file(Rails.root.join("soya/#{name}.yaml")).dig("content", "overlays")
        .find { |overlay| overlay["type"] == "OverlayClassification" }
  end

  def bundled(name)
    JSON.parse(Rails.root.join("soya/#{name}.jsonld").read)
  end
end
