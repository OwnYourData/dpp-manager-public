require "test_helper"

# The context is the whole point of these tests.
#
# soya-js loads the shared JSON-LD context with its own HTTP client, straight to
# ns.ownyourdata.eu, ignoring the repository it was configured with. A structure
# stored without resolving it therefore still needs a network at the moment a
# form is generated or data is validated — which is exactly the moment the
# operator is least likely to have one, and the failure says nothing about a
# context.
class SoyaRepositoryTest < ActiveSupport::TestCase
  CONTEXT = { "soya" => "https://w3id.org/soya/ns#", "Base" => "soya:Base" }.freeze

  test "an @import inside the context object is replaced by the context itself" do
    document = {
      "@context" => { "xsd" => "x", "@base" => "b", "@import" => Soya::Repository::CONTEXT_URL, "@version" => 1.1 },
      "@graph" => []
    }

    with_context do
      resolved = Soya::Repository.inline_context(document)["@context"]

      assert_equal "https://w3id.org/soya/ns#", resolved["soya"], "the imported terms are missing"
      assert_equal "b", resolved["@base"], "the structure's own keys must survive"
      assert_equal 1.1, resolved["@version"]
      assert_not resolved.key?("@import"), "nothing must be left to fetch"
    end
  end

  test "a context given as a bare url is replaced too" do
    with_context do
      document = { "@context" => Soya::Repository::CONTEXT_URL, "@graph" => [] }
      assert_equal CONTEXT, Soya::Repository.inline_context(document)["@context"]
    end
  end

  test "a context list keeps its other entries" do
    with_context do
      document = { "@context" => [ Soya::Repository::CONTEXT_URL, { "own" => "term" } ], "@graph" => [] }
      resolved = Soya::Repository.inline_context(document)["@context"]

      assert_equal [ CONTEXT, { "own" => "term" } ], resolved
    end
  end

  test "a context that names nothing familiar is left exactly as it was" do
    document = { "@context" => { "@base" => "b" }, "@graph" => [] }
    assert_equal document, Soya::Repository.inline_context(document)
  end

  # A repository that is reachable but whose context is not is a worse outcome
  # if it aborts the import: the structure still works with a network, and the
  # operator ends up with a type rather than an error they cannot act on.
  test "a context that cannot be fetched leaves the structure importable" do
    Soya::Repository.instance_variable_set(:@context_document, nil)

    stubbing(Soya::Http, :get_json, ->(_uri, **) { raise Soya::Error, "unreachable" }) do
      document = { "@context" => { "@import" => Soya::Repository::CONTEXT_URL }, "@graph" => [] }
      assert_equal document, Soya::Repository.inline_context(document)
    end
  ensure
    Soya::Repository.instance_variable_set(:@context_document, nil)
  end

  test "an answer that is not a structure is refused rather than stored" do
    stubbing(Soya::Http, :get_json, ->(_uri, **) { { "message" => "not found" } }) do
      assert_raises(Soya::Error) { Soya::Repository.fetch("https://soya.example", "Lamp") }
    end
  end

  test "a structure name that would leave the repository's namespace is refused" do
    assert_raises(Soya::Error) { Soya::Repository.fetch("https://soya.example", "../etc/passwd") }
  end

  private

  def with_context
    Soya::Repository.instance_variable_set(:@context_document, nil)
    stubbing(Soya::Http, :get_json, ->(_uri, **) { { "@context" => CONTEXT } }) { yield }
  ensure
    Soya::Repository.instance_variable_set(:@context_document, nil)
  end
end
