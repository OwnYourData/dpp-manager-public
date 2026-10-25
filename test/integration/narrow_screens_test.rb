require "test_helper"

# A window 375 px wide, as on a phone: the event log and the card of the data
# file stay inside the page. What makes them do so is CSS, so the test holds
# the markup the rules hang on and the rules themselves; the screenshots of the
# release check show the result.
class NarrowScreensTest < ActionDispatch::IntegrationTest
  CSS = Rails.root.join("app/assets/stylesheets/app.css")

  # The block of the stylesheet that starts with +head+ at the beginning of a
  # line, up to its closing brace.
  def rule(head)
    File.read(CSS)[/^#{Regexp.escape(head)} \{.*?\n?\}/m].to_s
  end

  test "the event log puts its filter on more lines and its events one under the other" do
    with_open_vault do
      create_and_unlock

      get events_path

      assert_response :success
      assert_select "form.filters select#kind"
      assert_select "table.events tbody tr"
    end
    assert_includes rule(".filters"), "flex-wrap: wrap"
    assert_includes rule(".filters select"), "max-width: 100%"
    narrow = File.read(CSS)[/@media \(max-width: 44rem\) \{\n  table\.events.*?\n\}/m].to_s
    assert_includes narrow, "table.events, table.events tbody, table.events tr, table.events td { display: block; }"
    assert_includes narrow, "table.events thead { position: absolute;"
  end

  test "the card of the data file breaks a long path instead of widening the page" do
    with_open_vault do
      create_and_unlock

      get root_path

      assert_select ".card dl dd code", text: Vault::Store.path.to_s
    end
    assert_includes rule(".card"), "min-width: 0;"
    assert_includes rule("dl"), "grid-template-columns: auto minmax(0, 1fr)"
    assert_includes rule("dd"), "overflow-wrap: anywhere"
  end
end
