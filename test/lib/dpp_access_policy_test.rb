require "test_helper"

# The access policy as the DPP Service takes it.
#
# The schema in test/fixtures/files is a copy of the service's
# config/vocab/access-policy.schema.json. It is checked here by hand rather than
# with a validator gem: the schema is small, and what matters is that every
# member this application writes is one the service knows.
class DppAccessPolicyTest < ActiveSupport::TestCase
  SCHEMA = JSON.parse(Rails.root.join("test/fixtures/files/access-policy.schema.json").read)
  DID = "did:oyd:zQmWxYzabcdefgh".freeze

  test "a class is read as notation or as IRI, and nothing else is a class" do
    assert_equal "legitimateInterest", Dpp::AccessPolicy.notation("legitimateInterest")
    assert_equal "authority", Dpp::AccessPolicy.notation("https://w3id.org/soya/dpp-access/v1#authority")
    assert_nil Dpp::AccessPolicy.notation("pii")
    assert_nil Dpp::AccessPolicy.notation("https://example.org/other#public")
  end

  test "the stricter of two classes wins" do
    assert_equal "authority", Dpp::AccessPolicy.stricter("public", "authority")
    assert_equal "legitimateInterest", Dpp::AccessPolicy.stricter("legitimateInterest", "public")
    assert_equal "public", Dpp::AccessPolicy.stricter(nil, "public")
  end

  # From the overlay where it says something, public where a field is
  # traced and it says nothing, authority where no field leads.
  test "the starting class follows the structure, then public, then authority" do
    rows = [
      { "path" => "A/Serial", "fields" => [ "serialNumber" ] },
      { "path" => "A/Name", "fields" => [ "name" ] },
      { "path" => "A/Both", "fields" => [ "name", "serialNumber" ] },
      { "path" => "A/Computed", "fields" => [] }
    ]

    classes = Dpp::AccessPolicy.suggested(rows, "serialNumber" => "legitimateInterest")

    assert_equal({ "A/Serial" => "legitimateInterest", "A/Name" => "public",
                   "A/Both" => "legitimateInterest", "A/Computed" => "authority" }, classes)
  end

  test "the policy is a document of the service's schema" do
    policy = Dpp::AccessPolicy.build(id: Dpp::AccessPolicy.id_for(DID, "DppLedLamp", 3), title: "LED lamp",
                                     classes: { "B/X" => "public", "A/Y" => "legitimateInterest" })

    assert_schema_valid policy
    assert_equal [ "A/Y", "B/X" ], policy["rules"].map { |rule| rule["path"] }, "in path order"
    assert_not policy.key?("default"), "what no rule reaches stays authority"
  end

  test "the id is an absolute URI in printable ASCII under the operator's DID" do
    id = Dpp::AccessPolicy.id_for(DID, "DppLedLamp", 2)

    assert_equal "#{DID}/access-policies/DppLedLamp/2", id
    assert URI.parse(id).absolute?
    assert_match(/\A[!-~]+\z/, id)
  end

  test "the digest follows the rules, not the order they were given in" do
    a = Dpp::AccessPolicy.digest("A" => "public", "B" => "authority")
    b = Dpp::AccessPolicy.digest("B" => "authority", "A" => "public")
    c = Dpp::AccessPolicy.digest("A" => "public", "B" => "legitimateInterest")

    assert_equal a, b
    assert_not_equal a, c
  end

  private

  def assert_schema_valid(policy)
    assert_empty SCHEMA["required"] - policy.keys, "required members"
    assert_empty policy.keys - SCHEMA["properties"].keys, "no members the schema does not know"
    assert_equal SCHEMA.dig("properties", "scheme", "const"), policy["scheme"]

    rule_schema = SCHEMA.dig("properties", "rules", "items")
    classes = SCHEMA.dig("$defs", "accessClass", "enum")
    pattern = Regexp.new(rule_schema.dig("properties", "path", "pattern"))
    policy["rules"].each do |rule|
      assert_equal rule_schema["required"].sort, rule.keys.sort
      assert_match pattern, rule["path"]
      assert_includes classes, rule["accessClass"]
    end
  end
end
