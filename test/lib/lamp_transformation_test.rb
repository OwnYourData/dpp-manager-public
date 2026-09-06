require "test_helper"
require "open3"
require "tempfile"

# The jq that turns a lamp's form answers into the element model of EN 18223.
#
# It is tested here rather than through soya-web-cli on purpose: at runtime the
# programme comes from the copy stored in the vault, but the thing that is
# authored, reviewed and published is soya/DppLedLampToEN18223.yaml. That is
# what these vectors pin. jq is in the image, so this runs wherever the suite
# runs.
#
# A transformation is the one place where being silently wrong is easy: a
# missing answer, a false, a zero and an empty list all look like "nothing" to
# a careless filter, and the resulting document is well-formed and untrue.
class LampTransformationTest < ActiveSupport::TestCase
  STRUCTURE = Rails.root.join("soya/DppLedLampToEN18223.yaml")

  FULL = {
    "modelIdentifier" => "LUM-A60-827-806",
    "manufacturerName" => "Lumina Leuchten GmbH",
    "productDesignation" => "Lumina A60 warmweiß",
    "serialNumber" => "",
    "dateOfManufacture" => "2026-03-14",
    "countryOfOrigin" => "AT",
    "usefulLuminousFlux" => 806,
    "onModePower" => 8.5,
    "standbyPower" => 0,
    "colourTemperature" => 2700,
    "colourRenderingIndex" => 80,
    "beamAngle" => 300,
    "typeOfDimming" => "none",
    "ratedLifetime" => 15_000,
    "guaranteedSwitchingCycles" => 100_000,
    "warrantyPeriodYears" => 3,
    "ceMarking" => "CE-2026-0815",
    "rohsCompliant" => true,
    "containsSvhc" => false,
    "svhcSubstances" => [],
    "energyEfficiencyClass" => "E",
    "carbonFootprint" => 1.8,
    "declarationOfConformity" => "https://docs.lumina.example/doc/LUM-A60.pdf",
    "dismantlingInstructions" => ""
  }.freeze

  # The three things soya-js looks at, and every one of them fails silently.
  #
  # The programme goes in `value`, not in `transformation`. soya-js reads
  # `item.value` (lib2/src/overlays/transform.ts, SoyaTransform#run), and the
  # repository drops the other key on the way into JSON-LD — so a structure
  # written with `transformation:` publishes cleanly, is pulled cleanly, and
  # then has nothing to run. It cost a milestone to find that out, which is why
  # it is asserted here rather than trusted.
  test "the overlay is the one shape soya transform will look for" do
    overlay = YAML.safe_load_file(STRUCTURE).dig("content", "overlays", 0)

    assert_equal "OverlayTransformation", overlay["type"]
    assert_equal "jq", overlay["engine"],
      "soya transform picks the first overlay carrying an engine field; without it nothing runs"
    assert overlay["value"].present?,
      "the jq belongs in `value`: soya-js reads item.value and never looks at any other key"
    assert_nil overlay["transformation"],
      "`transformation:` is silently dropped when the repository converts the YAML"
    assert_equal 1, YAML.safe_load_file(STRUCTURE).dig("content", "overlays").size,
      "one transformation per structure — there is no selecting between two"
  end

  test "the collections follow the service's element model" do
    elements = transform(FULL)

    assert_equal %w[ProductIdentification EnergyPerformance LightQuality Durability
                    Compliance SubstancesOfConcern EnvironmentalFootprint],
      elements.filter_map { |e| e["elementId"] if e["objectType"] == "DataElementCollection" }

    assert(elements.all? { |e| e["objectType"].present? }, "every node names its object type")
  end

  # An unanswered field must not become an element. A document that carries
  # `value: null` states that the value is null, which is a claim nobody made.
  test "an unanswered field leaves no element behind" do
    ids = element_ids(transform(FULL))

    assert_not_includes ids, "SerialNumber", "an empty answer became an element"
    assert_not_includes ids, "DismantlingInstructions"
    assert_includes ids, "ModelIdentifier"
  end

  # The trap this test exists for: a filter that drops "empty" answers by
  # truthiness drops these two as well, and the passport then says nothing about
  # standby power and nothing about substances of concern — while the operator
  # answered both.
  test "a zero and a false are answers and survive" do
    elements = transform(FULL)

    standby = find_element(elements, "StandbyPower")
    assert_equal 0, standby["value"]
    assert_equal "W", standby["unitOfMeasure"]

    contains = find_element(elements, "ContainsSubstancesOfVeryHighConcern")
    assert_equal false, contains["value"], "\"contains none\" is a statement, not a missing answer"
  end

  test "a collection with nothing in it is left out rather than left empty" do
    elements = transform({ "modelIdentifier" => "X-1" })

    assert_equal %w[ProductIdentification], elements.map { |e| e["elementId"] },
      "an empty DataElementCollection would claim the group is known and empty"
  end

  test "several substances become one multi-valued element, and the blanks in between do not" do
    elements = transform(FULL.merge(
      "containsSvhc" => true,
      "svhcSubstances" => [ "Blei (CAS 7439-92-1)", "", "Bis(2-ethylhexyl)phthalat (CAS 117-81-7)" ]
    ))

    multi = find_element(elements, "SubstancesOfVeryHighConcern")
    assert_equal "MultiValuedDataElement", multi["objectType"]
    assert_equal 2, multi["elements"].size, "the blank entry was carried into the document"
    assert_equal [ "SubstanceName" ], multi["elements"].map { |e| e["elementId"] }.uniq,
      "the children are repetitions of one value, so they share an elementId"
  end

  test "documents are referenced and their type is not guessed from the address" do
    resource = transform(FULL).find { |e| e["objectType"] == "RelatedResource" }

    assert_equal "DeclarationOfConformity", resource["elementId"]
    assert_equal "https://docs.lumina.example/doc/LUM-A60.pdf", resource["url"]
    assert_not resource.key?("contentType"),
      "a URL ending in .pdf is not a promise about what is served"
  end

  test "units and datatypes are the ones the standard's example uses" do
    elements = transform(FULL)

    assert_equal [ "xsd:integer", "lm" ], find_element(elements, "LuminousFlux").values_at("valueDataType", "unitOfMeasure")
    assert_equal [ "xsd:integer", "K" ],  find_element(elements, "CorrelatedColourTemperature").values_at("valueDataType", "unitOfMeasure")
    assert_equal [ "xsd:integer", "h" ],  find_element(elements, "RatedLifetime").values_at("valueDataType", "unitOfMeasure")
    assert_equal "xsd:date",              find_element(elements, "DateOfManufacture")["valueDataType"]
    assert_equal "xsd:boolean",           find_element(elements, "RoHSCompliant")["valueDataType"]
  end

  private

  def transform(answers)
    programme = YAML.safe_load_file(STRUCTURE).dig("content", "overlays", 0, "value")

    Tempfile.create([ "lamp", ".jq" ]) do |file|
      file.write(programme)
      file.flush

      out, err, status = Open3.capture3("jq", "-f", file.path, stdin_data: JSON.generate(answers))
      flunk("jq failed: #{err}") unless status.success?
      JSON.parse(out)
    end
  end

  def element_ids(elements)
    elements.flat_map { |e| [ e["elementId"] ] + (e["elements"] || []).flat_map { |c| [ c["elementId"] ] + (c["elements"] || []).map { |g| g["elementId"] } } }
  end

  def find_element(elements, id)
    elements.each do |node|
      return node if node["elementId"] == id
      (node["elements"] || []).each do |child|
        return child if child["elementId"] == id
        (child["elements"] || []).each { |grandchild| return grandchild if grandchild["elementId"] == id }
      end
    end
    flunk("no element #{id} in the document")
  end
end
