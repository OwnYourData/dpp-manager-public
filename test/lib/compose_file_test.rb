require "test_helper"
require "yaml"

# The configuration route 2b of the installation guide downloads.
class ComposeFileTest < ActiveSupport::TestCase
  test "the container name can be set like port and folder, and stays dpp-manager by default" do
    service = YAML.load_file(Rails.root.join("docker-compose.yml")).dig("services", "dpp-manager")

    assert_equal "${DPP_MANAGER_CONTAINER:-dpp-manager}", service["container_name"]
    assert_equal [ "${DPP_MANAGER_PORT:-3000}:3000" ], service["ports"]
    assert_equal [ "${DPP_MANAGER_DATA:-./data}:/data" ], service["volumes"]
  end

  test "the installation guide says how to give a second one its own name" do
    guide = File.read(Rails.root.join("docs/Install.md"))

    assert_includes guide, "DPP_MANAGER_CONTAINER=dpp-manager-2"
    assert_includes guide, "Privacy & Security"
  end
end
