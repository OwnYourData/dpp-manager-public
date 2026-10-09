require "test_helper"

# Turning rdf-validate-shacl's report into sentences an operator can act on.
#
# The report is written for a machine and every part of it shows: the message is
# a list of RDF literal terms rather than a string, the property is an IRI mixed
# in among the entry's other values, and a violated sh:in names the blank node
# that holds the list instead of what is in it. Passed through as it stands, a
# saved draft answered with
#
#   [{"value"=>"Value is not in Blank node df_6_121", "datatype"=>…}]
#
# which is a stack trace with a full stop.
class SoyaValidationTest < ActiveSupport::TestCase
  FORM = {
    "schema" => {
      "properties" => {
        "colourTemperature"     => { "type" => "integer" },
        "energyEfficiencyClass" => { "type" => "string", "enum" => %w[A B C D E F G] },
        "manufacturerName"      => { "type" => "string", "title" => "Manufacturer" },
        "countryOfOrigin"       => { "type" => "string", "pattern" => "^[A-Z]{2}$" },
        "usefulLuminousFlux"    => { "type" => "integer" }
      }
    },
    "ui" => {
      "type" => "VerticalLayout",
      "elements" => [
        { "type" => "Control", "scope" => "#/properties/colourTemperature", "label" => "Farbtemperatur (K)" },
        { "type" => "Control", "scope" => "#/properties/energyEfficiencyClass", "label" => "Energieeffizienzklasse" },
        { "type" => "Control", "scope" => "#/properties/countryOfOrigin", "label" => "Ursprungsland" },
        { "type" => "Control", "scope" => "#/properties/usefulLuminousFlux", "label" => "Nutzlichtstrom (lm)" }
      ]
    }
  }.freeze

  # The validation overlay as the structure's JSON-LD carries it: the message of
  # countryOfOrigin in two languages, which is exactly the shape that reaches the
  # report as a blank node.
  STRUCTURE = {
    "@graph" => [
      { "@id" => "DppLedLampOverlayValidation", "@type" => "OverlayValidation",
        "sh:property" => [
          { "sh:path" => "countryOfOrigin", "sh:pattern" => "^[A-Z]{2}$", "sh:minCount" => 1,
            "sh:message" => { "de" => "Zwei Großbuchstaben, zum Beispiel DE.",
                              "en" => "Two capital letters, for example DE." } },
          { "sh:path" => "usefulLuminousFlux", "sh:minCount" => 1 }
        ] }
    ]
  }.freeze

  def literal(text)
    [ { "value" => text, "datatype" => { "value" => "http://www.w3.org/2001/XMLSchema#string" }, "language" => "" } ]
  end

  test "a literal message becomes a sentence, named after the field it is about" do
    report = { "results" => [
      { "id" => "https://soya.ownyourdata.eu/DppLedLamp/colourTemperature",
        "message" => literal("Value is not greater than or equal to 1500") }
    ] }

    assert_equal [ "Farbtemperatur (K): Value is not greater than or equal to 1500" ],
      Soya::Validation.problems_in(report, type)
  end

  # The label comes from the form control, because that is the word the operator
  # just read next to the field they filled in. The schema title is the fallback,
  # and the bare key the last resort — never nothing.
  test "the label is the one on the form, or the schema's, or the key" do
    problems = Soya::Validation.problems_in({ "results" => [
      { "id" => "https://soya.ownyourdata.eu/DppLedLamp/manufacturerName", "message" => literal("too short") }
    ] }, type)

    assert_equal [ "Manufacturer: too short" ], problems
  end

  # "Value is not in Blank node df_6_121" is the library naming the node that
  # holds the list. The list is in the form's own schema, so the answer is there
  # to be given.
  test "a violated closed list says what is allowed instead of naming a blank node" do
    report = { "results" => [
      { "id" => "https://soya.ownyourdata.eu/DppLedLamp/energyEfficiencyClass",
        "message" => literal("Value is not in Blank node df_6_121") }
    ] }

    assert_equal [ "Energieeffizienzklasse: muss einer dieser Werte sein: A, B, C, D, E, F, G" ],
      I18n.with_locale(:de) { Soya::Validation.problems_in(report, type) }
  end

  # soya-js builds each result as { id: focusNode, message, ...path }, so which
  # key carries the property IRI depends on what the RDF term happened to hold.
  # The field is therefore looked for in every value, and only a segment that is
  # actually a field of this form is accepted — which is what makes that safe.
  test "the field is found wherever in the entry its IRI turns up" do
    report = { "results" => [
      { "id" => "_:df_5_0",
        "path" => { "value" => "https://soya.ownyourdata.eu/DppLedLamp/colourTemperature" },
        "message" => literal("Value is not greater than or equal to 1500") }
    ] }

    assert_equal [ "Farbtemperatur (K): Value is not greater than or equal to 1500" ],
      Soya::Validation.problems_in(report, type)
  end

  test "an entry about nothing this form knows is still readable" do
    report = { "results" => [
      { "id" => "https://example.org/Something/else", "message" => literal("Value is not a date") }
    ] }

    assert_equal [ "Value is not a date" ], Soya::Validation.problems_in(report, type)
  end

  # Seen in the probe of 25.09.2026: "Country of origin: df_13_85". The
  # structure's own sentence was there all along, in both languages.
  test "a message the library reports as a blank node is the structure's own, in the operator's language" do
    report = { "results" => [
      { "id" => { "termType" => "BlankNode", "value" => "df_16_0" },
        "value" => "https://soya.ownyourdata.eu/DppLedLamp/countryOfOrigin",
        "message" => literal("df_17_85") }
    ] }

    assert_equal [ "Ursprungsland: Zwei Großbuchstaben, zum Beispiel DE." ],
      I18n.with_locale(:de) { Soya::Validation.problems_in(report, type_with_structure) }
    assert_equal [ "Ursprungsland: Two capital letters, for example DE." ],
      I18n.with_locale(:en) { Soya::Validation.problems_in(report, type_with_structure) }
  end

  test "a blank node with no message behind it is not shown as its name" do
    report = { "results" => [
      { "value" => "https://soya.ownyourdata.eu/DppLedLamp/colourTemperature", "message" => literal("df_17_85") }
    ] }

    assert_equal [ "Farbtemperatur (K): #{I18n.t('passports.problem.unnamed')}" ],
      Soya::Validation.problems_in(report, type_with_structure)
  end

  # "Less than 1 values" is sh:minCount 1 failing: an empty mandatory field.
  test "an empty mandatory field says so in words" do
    report = { "results" => [
      { "value" => "https://soya.ownyourdata.eu/DppLedLamp/usefulLuminousFlux",
        "message" => literal("Less than 1 values") }
    ] }

    assert_equal [ "Nutzlichtstrom (lm): fehlt" ],
      I18n.with_locale(:de) { Soya::Validation.problems_in(report, type_with_structure) }
    assert_equal [ "Nutzlichtstrom (lm): is required" ],
      I18n.with_locale(:en) { Soya::Validation.problems_in(report, type_with_structure) }
  end

  test "a field given twice says it takes one value" do
    report = { "results" => [
      { "value" => "https://soya.ownyourdata.eu/DppLedLamp/usefulLuminousFlux",
        "message" => literal("More than 1 values") }
    ] }

    assert_equal [ "Nutzlichtstrom (lm): nimmt nur einen Wert" ],
      I18n.with_locale(:de) { Soya::Validation.problems_in(report, type_with_structure) }
  end

  test "an entry with no message at all does not become an empty bullet" do
    problems = Soya::Validation.problems_in({ "results" => [ { "id" => "_:df_5_0" } ] }, type)

    assert_equal [ I18n.t("passports.problem.unnamed") ], problems
  end

  # The class check is the failure that reports no violations at all: nothing in
  # the data is of the type the shapes target, so SHACL has nothing to say and
  # calling that "valid" would be the worst kind of wrong answer.
  test "a missing target class reads as a sentence, not as an IRI" do
    report = { "classChecks" => [ { "message" => "Missing class",
                                    "name" => "https://soya.ownyourdata.eu/DppLedLamp/DppLedLamp" } ] }

    assert_equal [ I18n.t("passports.problem.missing_class", name: "DppLedLamp") ],
      Soya::Validation.problems_in(report, type)
  end

  test "a report with no product type behind it still says something" do
    report = { "results" => [ { "id" => "x", "message" => literal("Value is not a date") } ] }

    assert_equal [ "Value is not a date" ], Soya::Validation.problems_in(report)
  end

  private

  # Only the form is needed here, and a real ProductType would need a vault to be
  # open to know its own columns. What is under test is the report, not the row.
  Type = Struct.new(:form, :structure) do
    def form_for(_language) = form
  end

  def type = @type ||= Type.new(FORM)

  def type_with_structure = @type_with_structure ||= Type.new(FORM, STRUCTURE)
end
