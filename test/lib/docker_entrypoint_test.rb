require "test_helper"

# The checks bin/docker-entrypoint makes before the application starts. They are
# read in the container's log, so they give the remedy the page and the
# installation guide give.
class DockerEntrypointTest < ActiveSupport::TestCase
  test "a data directory that cannot be written to gets the remedy for Docker Desktop too" do
    script = File.read(Rails.root.join("bin/docker-entrypoint"))

    assert_no_match(/handles this for you/, script)
    assert_includes script, "chown -R 1000:1000"
    assert_includes script, "must not be read-only"
    assert_includes script, "System Settings → Privacy & Security → Files and Folders"
    assert_includes script, "The installation guide, section 7, has the details."
  end
end
