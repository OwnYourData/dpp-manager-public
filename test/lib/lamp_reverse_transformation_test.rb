require "test_helper"
require "open3"
require "tempfile"

# The jq that reads an EN 18223 element tree back into the lamp's form answers.
#
# Tested against the forward transformation rather than against a fixture: what
# matters is that the pair agrees, and a hand-written expected document would
# only pin what I believed the forward direction produces. The two programmes
# are run one after the other here, and the answers that go in have to come back.
#
# It is not a lossless inverse and the tests say where it is not: units, value
# types and the collection an element sat in are given away on the way there and
# cannot come back.
class LampReverseTransformationTest < ActiveSupport::TestCase
  FORWARD = Rails.root.join("soya/DppLedLampToEN18223.yaml")
  REVERSE = Rails.root.join("soya/DppLedLampFromEN18223.yaml")

  ANSWERS = {
    "modelIdentifier" => "LUM-A60-827-806",
    "manufacturerName" => "Lumina Leuchten GmbH",
    "productDesignation" => "Lumina A60 warmweiß",
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
    "energyEfficiencyClass" => "E",
    "carbonFootprint" => 1.8,
    "declarationOfConformity" => "https://docs.lumina.example/doc/LUM-A60.pdf"
  }.freeze

  test "the overlay is the one shape soya transform will look for" do
    overlay = YAML.safe_load_file(REVERSE).dig("content", "overlays", 0)

    assert_equal "OverlayTransformation", overlay["type"]
    assert_equal "jq", overlay["engine"]
    assert overlay["value"].present?,
      "the jq belongs in `value`: soya-js reads item.value and never looks at any other key"
    assert_nil overlay["transformation"]
    assert_equal 1, YAML.safe_load_file(REVERSE).dig("content", "overlays").size,
      "one transformation per structure — the way there is a structure of its own"
  end

  test "what goes out through the forward transformation comes back through this one" do
    assert_equal ANSWERS, read_back(ANSWERS)
  end

  # The one that would be silently wrong: `false` is an answer. A filter that
  # drops what is not truthy loses "contains no substances of very high concern",
  # which is the statement most worth keeping.
  test "a false and a zero survive the way back" do
    back = read_back(ANSWERS)

    assert_equal false, back["containsSvhc"]
    assert_equal 0, back["standbyPower"]
  end

  test "repetitions come back as the list they were" do
    back = read_back(ANSWERS.merge("containsSvhc" => true,
                                   "svhcSubstances" => [ "Blei (CAS 7439-92-1)", "Cadmium" ]))

    assert_equal [ "Blei (CAS 7439-92-1)", "Cadmium" ], back["svhcSubstances"]
  end

  # A document written by somebody else may state a number as a string — the
  # standard allows it, and JSON Forms renders an empty field for it. The
  # declared value type is what says how to read it.
  test "a number written as a string is read as a number" do
    document = envelope(forward(ANSWERS))
    as_text  = JSON.parse(JSON.generate(document).gsub(/"value":(-?\d+(\.\d+)?)/) { "\"value\":\"#{$1}\"" })

    back = reverse(as_text)

    assert_equal 806, back["usefulLuminousFlux"]
    assert_equal 8.5, back["onModePower"]
    assert_equal true, back["rohsCompliant"], "a boolean written as text is a boolean"
  end

  # What is not in the document must not become an empty answer: JSON Forms shows
  # a field answered with null as an error, and nobody made that claim.
  test "a field the document does not mention is left out, not emptied" do
    back = reverse(envelope(forward({ "modelIdentifier" => "X-1" })))

    assert_equal({ "modelIdentifier" => "X-1" }, back)
  end

  # An element is matched by its id wherever it sits. Another author may group
  # the same elements differently, and a reading that depended on the grouping
  # would find nothing in a document that is entirely correct.
  test "an element is found wherever the document happens to put it" do
    flat = { "elements" => forward(ANSWERS).flat_map { |node| node["elements"] || [ node ] } }

    assert_equal 2700, reverse(flat)["colourTemperature"]
  end

  test "a passport with no elements at all yields nothing rather than failing" do
    assert_equal({}, reverse({ "elements" => [] }))
  end

  private

  def read_back(answers) = reverse(envelope(forward(answers)))

  def envelope(elements)
    { "digitalProductPassportId" => "did:oyd:zQmExample",
      "uniqueProductIdentifier" => "https://id.example.com/01/09520123456788/21/1",
      "granularity" => "item", "dppStatus" => "Active", "elements" => elements }
  end

  def forward(answers) = apply(FORWARD, answers)

  def reverse(document) = apply(REVERSE, document)

  def apply(structure, input)
    programme = YAML.safe_load_file(structure).dig("content", "overlays", 0, "value")

    Tempfile.create([ "lamp", ".jq" ]) do |file|
      file.write(programme)
      file.flush

      out, err, status = Open3.capture3("jq", "-f", file.path, stdin_data: JSON.generate(input))
      flunk("jq failed: #{err}") unless status.success?
      JSON.parse(out)
    end
  end
end
