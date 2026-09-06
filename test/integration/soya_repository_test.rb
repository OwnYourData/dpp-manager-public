require "test_helper"

# The application, seen from soya-web-cli.
#
# These routes serve the operator's structures to a process that has no session
# and cannot have one. What keeps them from being a hole is the address they
# answer to: soya-web-cli shares the loopback interface with nothing, while a
# request that arrives through the published port comes from the container's
# gateway.
class SoyaRepositoryEndpointTest < ActionDispatch::IntegrationTest
  test "soya-web-cli can pull a structure and its yaml" do
    with_open_vault do
      create_and_unlock
      type = create_type

      get "/soya/#{type.resolvable_name}"
      assert_response :success
      assert_equal "Lamp", JSON.parse(response.body).dig("@graph", 0, "name")

      get "/soya/#{type.resolvable_name}/yaml"
      assert_response :success
      assert_match "meta:", response.body
    end
  end

  # A type carries three structures now, and all three are pulled through here by
  # name. Which one comes back is decided by which of the row's name columns the
  # name matches — and getting that wrong would answer the reading transformation
  # with the form's structure, which parses cleanly and transforms nothing.
  test "each of a type's three structures comes back under its own name" do
    with_open_vault do
      create_and_unlock
      type = create_type(
        transformation_name: "LampToEN", transformation_fetched_at: Time.current,
        transformation_jsonld: { "@graph" => [ { "name" => "forward" } ] }.to_json,
        reverse_transformation_name: "LampFromEN", reverse_transformation_fetched_at: Time.current,
        reverse_transformation_jsonld: { "@graph" => [ { "name" => "backward" } ] }.to_json
      )

      get "/soya/#{type.resolvable_name}"
      assert_equal "Lamp", JSON.parse(response.body).dig("@graph", 0, "name")

      get "/soya/#{type.transformation_resolvable_name}"
      assert_equal "forward", JSON.parse(response.body).dig("@graph", 0, "name")

      get "/soya/#{type.reverse_transformation_resolvable_name}"
      assert_equal "backward", JSON.parse(response.body).dig("@graph", 0, "name")
    end
  end

  test "a request from anywhere but the loopback address is refused" do
    with_open_vault do
      create_and_unlock
      type = create_type

      # What a request published to the host looks like: the container gateway.
      get "/soya/#{type.resolvable_name}", headers: { "REMOTE_ADDR" => "172.17.0.1" }
      assert_response :forbidden
    end
  end

  test "a locked vault says so rather than pretending the structure is missing" do
    with_open_vault do
      create_and_unlock
      type = create_type
      name = type.resolvable_name
      Vault::Store.close!

      get "/soya/#{name}"
      assert_response :service_unavailable
    end
  end

  test "a structure that is not here answers not found" do
    with_open_vault do
      create_and_unlock
      get "/soya/Nonexistent~9~9"
      assert_response :not_found
    end
  end

  test "a structure without an author's yaml answers not found for it" do
    with_open_vault do
      create_and_unlock
      type = create_type(yaml: nil)

      get "/soya/#{type.resolvable_name}/yaml"
      assert_response :not_found
    end
  end

  test "the query endpoint answers with the resolvable names, not the plain ones" do
    with_open_vault do
      create_and_unlock
      type = create_type

      get "/soya/api/soya/query", params: { name: "Lam" }
      assert_response :success
      assert_equal [ type.resolvable_name ], JSON.parse(response.body).map { |row| row["name"] }
    end
  end

  private

  def create_type(**overrides)
    ProductType.create!({
      label: "Lamp", structure_name: "Lamp", repo_base_url: "https://soya.example",
      jsonld: { "@graph" => [ { "name" => "Lamp" } ] }.to_json,
      yaml: "meta:\n  name: Lamp\n",
      forms: { "en" => { "schema" => { "properties" => {} }, "ui" => {} } }.to_json,
      fetched_at: Time.current
    }.merge(overrides))
  end
end
