require "test_helper"
require "open3"
require "tempfile"

# Which form field ends up at which element path, worked out by running the
# transformation over marker answers.
#
# Against jq directly, as the transformation tests do: what is pinned here is
# the authored transformation and what the tracing makes of it. At runtime the
# same programme runs in soya-web-cli.
class AccessPathsTest < ActiveSupport::TestCase
  test "every field of the lamp lands on exactly one element" do
    rows = trace("DppLedLamp", "DppLedLampToEN18223")
    by_field = fields_to_paths(rows)

    assert_equal fields_of("DppLedLamp").sort, by_field.keys.sort, "no field left untraced"
    by_field.each { |field, paths| assert_equal 1, paths.size, "#{field} at #{paths.inspect}" }

    assert_equal [ "ProductIdentification/SerialNumber" ], by_field["serialNumber"]
    assert_equal [ "ProductIdentification/BrandName" ], by_field["manufacturerName"]
    assert_equal [ "ProductIdentification/DateOfManufacture" ], by_field["dateOfManufacture"], "a date carries a marker too"
    assert_equal [ "EnergyPerformance/OnModePower" ], by_field["onModePower"], "a decimal carries a marker too"
    assert_equal [ "DismantlingInstructions" ], by_field["dismantlingInstructions"]
  end

  # A boolean cannot carry a marker; it is traced in a run of its own, and its
  # element joins its collection rather than trailing at the end.
  test "a boolean is traced on its own and keeps its place" do
    rows = trace("DppLedLamp", "DppLedLampToEN18223")
    paths = rows.map { |row| row["path"] }

    assert_equal [ "Compliance/RoHSCompliant" ], fields_to_paths(rows)["rohsCompliant"]
    assert_equal paths.index("Compliance/CeMarking") + 1, paths.index("Compliance/RoHSCompliant")
  end

  # The items of a multi-valued element belong to it: one row, not one per item.
  test "a set of strings is one element" do
    by_field = fields_to_paths(trace("DppLedLamp", "DppLedLampToEN18223"))

    assert_equal [ "SubstancesOfConcern/SubstancesOfVeryHighConcern" ], by_field["svhcSubstances"]
  end

  test "every field of the battery lands on exactly one element, lists included" do
    rows = trace("DppBattery", "DppBatteryToEN18223")
    by_field = fields_to_paths(rows)

    assert_equal fields_of("DppBattery").sort, by_field.keys.sort
    by_field.each { |field, paths| assert_equal 1, paths.size, "#{field} at #{paths.inspect}" }

    # Items named by a value (the material) inside a multi-valued element.
    assert_equal [ "MaterialsAndComposition/CriticalRawMaterials" ], by_field["criticalRawMaterials"]
    # Collections named by a value (the substance): no path a policy could name
    # in advance, so the collection around them.
    assert_equal [ "MaterialsAndComposition/HazardousSubstances" ], by_field["hazardousSubstances"]
    # Items numbered by position: a third document must be covered as well.
    assert_equal [ "Documentation" ], by_field["documents"]
  end

  test "an element no field leads to is listed without fields" do
    structure = { "@graph" => [
      { "@id" => "T", "@type" => "owl:Class" },
      { "@id" => "name", "@type" => "owl:DatatypeProperty", "domain" => "T", "range" => "xsd:string" }
    ] }

    rows = Dpp::AccessPaths.trace(structure) do |answers|
      [ { "elementId" => "Info", "objectType" => "DataElementCollection", "elements" => [
          { "elementId" => "Name", "objectType" => "SingleValuedDataElement", "value" => answers["name"] },
          { "elementId" => "Edition", "objectType" => "SingleValuedDataElement", "value" => "2026" }
        ] } ]
    end

    assert_equal [ { "path" => "Info/Name", "fields" => [ "name" ] },
                   { "path" => "Info/Edition", "fields" => [] } ], rows
  end

  test "an answer that is not an element tree is said so" do
    assert_raises(Dpp::AccessPaths::Error) { Dpp::AccessPaths.elements_of("text") }
    assert_equal [ 1 ], Dpp::AccessPaths.elements_of("elements" => [ 1 ])
  end

  private

  def trace(structure, transformation)
    jsonld = JSON.parse(Rails.root.join("soya/#{structure}.jsonld").read)
    Dpp::AccessPaths.trace(jsonld) { |answers| Dpp::AccessPaths.elements_of(jq(transformation, answers)) }
  end

  def jq(transformation, answers)
    programme = YAML.safe_load_file(Rails.root.join("soya/#{transformation}.yaml")).dig("content", "overlays", 0, "value")

    Tempfile.create([ "access", ".jq" ]) do |file|
      file.write(programme)
      file.flush

      out, err, status = Open3.capture3("jq", "-f", file.path, stdin_data: JSON.generate(answers))
      flunk("jq failed: #{err}") unless status.success?
      JSON.parse(out)
    end
  end

  def fields_to_paths(rows)
    rows.each_with_object(Hash.new { |h, k| h[k] = [] }) do |row, map|
      row["fields"].each { |field| map[field] << row["path"] }
    end
  end

  # The fields of the main base, from the authored YAML.
  def fields_of(structure)
    YAML.safe_load_file(Rails.root.join("soya/#{structure}.yaml")).dig("content", "bases", 0, "attributes").keys
  end
end
