require "test_helper"

# The example files the passport form can be loaded from.
#
# They are documentation that runs: somebody opens a demo, picks a file from
# docs/examples/ and expects a filled form. If a structure gains a required
# attribute or renames one, the file goes quietly wrong — the form fills in, the
# passport saves, and the failure surfaces at the service. So each file is
# checked against the structure it claims to fit, with the same keywords the
# browser checks it with.
#
# Deliberately not a general JSON Schema implementation: only the keywords the
# bundled form overlays actually use are honoured, and an unknown one is a test
# failure rather than something silently skipped. That is what keeps this test
# honest as the structures grow — the battery brought `oneOf`, `maxItems` and
# object-shaped list items with it, and each of them had to be taught here
# before it could pass.
class ExampleAnswersTest < ActiveSupport::TestCase
  # Every bundled product type that ships an example. The base name is not
  # derivable from the structure name: the lamp calls its base after itself,
  # the battery calls it Battery.
  TYPES = [
    { label: "the LED lamp",
      example: "docs/examples/led-lamp.json", structure: "soya/DppLedLamp.yaml", base: "DppLedLamp" },
    { label: "the traction battery",
      example: "docs/examples/battery.json", structure: "soya/DppBattery.yaml", base: "Battery" }
  ].freeze

  KNOWN_KEYWORDS = %w[
    type enum oneOf minimum maximum minLength maxLength pattern format items maxItems
  ].freeze

  TYPES.each do |type|
    label = type[:label]

    test "#{label}: the example is a JSON object" do
      assert_kind_of Hash, answers(type)
    end

    test "#{label}: every field in the example exists in the structure" do
      assert_empty answers(type).keys - attributes(type).keys,
        "the example names fields the structure does not have"
    end

    test "#{label}: the example fills in everything the structure requires" do
      assert_empty required(type) - answers(type).keys,
        "the example is missing required fields, so the demo would open with errors"
    end

    # The point of the file is a complete passport, not a minimal one: a demo
    # that fills eleven of twenty-four fields shows less than it should.
    test "#{label}: the example fills in every field the structure offers" do
      assert_empty attributes(type).keys - answers(type).keys,
        "the example leaves fields empty that the structure offers"
    end

    test "#{label}: every value satisfies the constraints the form checks" do
      answers(type).each do |name, value|
        properties(type).fetch(name).each do |keyword, rule|
          assert_includes KNOWN_KEYWORDS, keyword,
            "#{name}: the form schema uses #{keyword}, which this test does not check"

          check(name, keyword, rule, value)
        end
      end
    end

    # Every element of a set is checked the same way the set's items say,
    # because a list is where a wrong type hides best. Two shapes occur: a list
    # of plain values, and a list of objects — and for the latter the item's own
    # required fields have to be there, which is exactly what the form refuses
    # to save without.
    test "#{label}: the items of a set satisfy their own constraints" do
      properties(type).each do |name, property|
        next unless property["type"] == "array"

        items = property.fetch("items")
        Array(answers(type)[name]).each_with_index do |item, index|
          where = "#{name}[#{index}]"

          if items["type"] == "object"
            Array(items["required"]).each do |field|
              assert item.key?(field), "#{where}: #{field} is required and missing"
            end
            item.each do |field, value|
              rules = items.fetch("properties")[field]
              assert rules, "#{where}: #{field} is not a field of this list"
              rules.each { |keyword, rule| check("#{where}.#{field}", keyword, rule, value) }
            end
          else
            items.each { |keyword, rule| check(where, keyword, rule, item) }
          end
        end
      end
    end
  end

  private

  def check(name, keyword, rule, value)
    case keyword
    when "type"      then assert of_type(rule, value), "#{name}: #{value.inspect} is not a #{rule}"
    when "enum"      then assert_includes rule, value, "#{name}: #{value.inspect} is not offered"
    when "oneOf"     then assert_includes rule.map { |o| o["const"] }, value,
                            "#{name}: #{value.inspect} is not one of the offered values"
    when "minimum"   then assert value >= rule, "#{name}: #{value} is below #{rule}"
    when "maximum"   then assert value <= rule, "#{name}: #{value} is above #{rule}"
    when "minLength" then assert value.length >= rule, "#{name}: shorter than #{rule}"
    when "maxLength" then assert value.length <= rule, "#{name}: longer than #{rule}"
    when "maxItems"  then assert value.length <= rule, "#{name}: more than #{rule} entries"
    when "pattern"   then assert_match Regexp.new(rule), value, "#{name}: does not match #{rule}"
    when "format"    then assert_match(/\A\d{4}-\d{2}-\d{2}\z/, value, "#{name}: not a date") if rule == "date"
    when "properties", "required", "items" then nil
    end
  end

  def of_type(expected, value)
    case expected
    when "string"  then value.is_a?(String)
    when "integer" then value.is_a?(Integer)
    # JSON Schema's number covers integers too, which matters for a power of 0.
    when "number"  then value.is_a?(Numeric)
    when "boolean" then [ true, false ].include?(value)
    when "array"   then value.is_a?(Array)
    when "object"  then value.is_a?(Hash)
    else false
    end
  end

  def answers(type)
    cache(type, :answers) { JSON.parse(Rails.root.join(type[:example]).read) }
  end

  def document(type)
    cache(type, :document) { YAML.safe_load_file(Rails.root.join(type[:structure])) }
  end

  def attributes(type)
    cache(type, :attributes) do
      base = document(type).dig("content", "bases").find { |b| b["name"] == type[:base] }
      assert base, "#{type[:structure]} has no base called #{type[:base]}"
      base["attributes"]
    end
  end

  def form_overlay(type)
    cache(type, :form) do
      document(type).dig("content", "overlays")
                    .find { |o| o["type"] == "OverlayForm" && o["language"] == "en" }
    end
  end

  def properties(type) = form_overlay(type).dig("schema", "properties")
  def required(type)   = form_overlay(type).dig("schema", "required")

  def cache(type, key)
    @cache ||= {}
    @cache[[ type[:structure], key ]] ||= yield
  end
end
