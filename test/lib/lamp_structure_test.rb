require "test_helper"

# The lamp structure's two halves have to say the same thing.
#
# The validation overlay is what the server checks; the form overlay's schema is
# what the browser checks, because JSON Forms validates against that and against
# nothing else. A limit that lives in only one of them is a limit somebody finds
# out about at the wrong moment — which is exactly what happened: the form let a
# colour temperature of 1 be typed, and the answer came back from the server.
#
# Repeating the constraints is the price of in-form validation. This test is what
# makes the repetition safe.
class LampStructureTest < ActiveSupport::TestCase
  STRUCTURE = Rails.root.join("soya/DppLedLamp.yaml")

  # What plain JSON Schema cannot express, and why it is left out rather than
  # approximated.
  NOT_IN_THE_FORM = {
    # A date bound needs ajv-formats' formatMinimum, which is not part of JSON
    # Schema and not something soya-form promises to load. The server checks it.
    "dateOfManufacture" => "valueRange"
  }.freeze

  test "every constraint the validation states is also in the form's schema" do
    validation.each do |name, rules|
      property = properties.fetch(name, {})

      expected(name, rules).each do |path, value|
        assert_equal value, property.dig(*path),
          "#{name}: the form schema says #{path.join('.')}=#{property.dig(*path).inspect}, " \
          "the validation says #{value.inspect}"
      end
    end
  end

  test "what is required in the validation is required in the form" do
    mandatory = validation.select { |_name, rules| rules["cardinality"].to_s.start_with?("1..") }.keys

    assert_equal mandatory.sort, form_overlay("en")["schema"]["required"].sort
  end

  # Two overlays, one per language. Only the labels may differ: a schema that
  # drifted between them would mean the same passport is valid in English and
  # not in German.
  test "the two languages share one schema" do
    assert_equal form_overlay("en")["schema"], form_overlay("de")["schema"]
  end

  # The rule that cost a milestone. An option written as `id: A` becomes the IRI
  # …/DppLedLamp/A in sh:in, while an attribute of range xsd:string carries the
  # literal "A" — and a literal is never in a list of IRIs, so every passport was
  # reported as violating a constraint it satisfied.
  test "a closed list over a string range holds literals, not identifiers" do
    validation.each do |name, rules|
      options = rules["valueOption"]
      next if options.blank?

      assert options.all? { |option| option.is_a?(String) },
        "#{name}: valueOption uses `id:`, so sh:in will hold IRIs and no answer can ever match"
    end
  end

  test "the form offers exactly the values the validation allows" do
    validation.each do |name, rules|
      next if rules["valueOption"].blank?

      assert_equal rules["valueOption"], properties.dig(name, "enum"),
        "#{name}: the form offers something other than what the validation permits"
    end
  end

  private

  def expected(name, rules)
    out = {}

    rules.each do |keyword, value|
      next if NOT_IN_THE_FORM[name] == keyword

      case keyword
      when "valueRange"
        min, max = bounds(value)
        out["minimum"] = min unless min.nil?
        out["maximum"] = max unless max.nil?
      when "length"
        min, max = bounds(value)
        # A minimum length of zero says nothing, and saying nothing is what an
        # absent keyword already does.
        out["minLength"] = min if min.to_i.positive?
        out["maxLength"] = max unless max.nil?
      when "pattern"
        out["pattern"] = value
      end
    end

    # A set carries its limits on the items, not on the array, so the path into
    # the schema is one level deeper.
    prefix = rules["cardinality"].to_s.end_with?("..n") ? [ "items" ] : []

    out.to_h { |keyword, value| [ prefix + [ keyword ], value ] }
  end

  # "[1500..10000]", "[0..]", "[2000-01-01..*]" — the open end is written three
  # ways in the wild, so all three mean "no bound".
  def bounds(range)
    inner = range.to_s.delete("[]")
    min, max = inner.split("..", 2)
    [ number(min), number(max) ]
  end

  def number(value)
    return nil if value.blank? || value == "*"

    Integer(value)
  rescue ArgumentError
    nil
  end

  def document = @document ||= YAML.safe_load_file(STRUCTURE)

  def overlays = document.dig("content", "overlays")

  def validation
    @validation ||= overlays.find { |overlay| overlay["type"] == "OverlayValidation" }["attributes"]
  end

  def form_overlay(language)
    overlays.find { |overlay| overlay["type"] == "OverlayForm" && overlay["language"] == language }
  end

  def properties = @properties ||= form_overlay("en").dig("schema", "properties")
end
