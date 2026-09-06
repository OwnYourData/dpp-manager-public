require "test_helper"

# The structures the image ships with.
#
# Two of these tests exist because of failures that already happened once. The
# jq under the wrong key published cleanly and ran nothing; a structure whose
# context is a URL rather than a document drags a network call behind it at the
# moment it is parsed. Both are invisible until an operator is standing in front
# of them, so both are checked against the files that actually ship.
class SoyaBundledTest < ActiveSupport::TestCase
  test "the manifest names structures whose files are all present" do
    assert Soya::Bundled.manifest.any?, "the image ships no product types at all"

    Soya::Bundled.names.each do |name|
      assert Soya::Bundled.dir.join("#{name}.jsonld").exist?,
        "#{name} is in the manifest but its JSON-LD was never exported — run rake soya:bundle"
    end
  end

  # The one that cost a milestone: soya-js reads `value`, the repository drops
  # anything else, and a transformation can therefore be published, pulled and
  # cached without ever carrying a programme.
  test "the bundled transformation carries the jq that was authored beside it" do
    authored = YAML.safe_load_file(Soya::Bundled.dir.join("DppLedLampToEN18223.yaml"))
                   .dig("content", "overlays", 0, "value")
    bundled  = JSON.parse(Soya::Bundled.dir.join("DppLedLampToEN18223.jsonld").read)
                   .dig("@graph", 0, "value")

    assert authored.present?
    assert_equal authored, bundled,
      "the exported copy is out of date — run rake soya:bundle after pushing the YAML"
  end

  # The way back ships too, and by the same rule: a fresh installation that has
  # never seen a network has to be able to read a foreign passport, not only
  # write its own.
  test "the bundled reading transformation carries the jq that was authored beside it" do
    authored = YAML.safe_load_file(Soya::Bundled.dir.join("DppLedLampFromEN18223.yaml"))
                   .dig("content", "overlays", 0, "value")
    bundled  = JSON.parse(Soya::Bundled.dir.join("DppLedLampFromEN18223.jsonld").read)
                   .dig("@graph", 0, "value")

    assert authored.present?
    assert_equal authored, bundled,
      "the exported copy is out of date — run rake soya:bundle after pushing the YAML"
  end

  # The staleness the two tests above cannot see. A transformation's jq is
  # compared with the YAML beside it, but the structure the form comes from was
  # only ever checked for being present — so a YAML that was pushed while the
  # export was not re-run leaves the image shipping the previous form, with the
  # limits that were added to it missing. That happened once, silently, and only
  # to installations without a network.
  test "the bundled structure's forms are the ones authored beside it" do
    authored = YAML.safe_load_file(Soya::Bundled.dir.join("DppLedLamp.yaml"))
                   .dig("content", "overlays")
                   .select { |overlay| overlay["type"] == "OverlayForm" }
                   .to_h { |overlay| [ overlay["language"], overlay["schema"] ] }
    bundled = JSON.parse(Soya::Bundled.dir.join("DppLedLamp.jsonld").read)["@graph"]
                  .select { |node| node["@type"].to_s.end_with?("OverlayForm") }
                  .to_h { |node| [ node["language"], node["schema"] ] }

    assert authored.any?, "the lamp structure carries no form overlay at all"
    assert_equal authored, bundled,
      "the exported copy is out of date — run rake soya:bundle after pushing the YAML"
  end

  # A bundled structure whose context is still a URL would reach ns.ownyourdata.eu
  # while soya-js parses it, and the promise that a fresh installation works
  # without a network would hold right up to the first form.
  test "nothing in a bundled structure points outside the image" do
    Soya::Bundled.names.each do |name|
      context = JSON.parse(Soya::Bundled.dir.join("#{name}.jsonld").read)["@context"]

      assert context.is_a?(Hash), "#{name}: the context is not an object"
      assert_not context.key?("@import"),
        "#{name}: the shared context is still a reference, not the document itself"
    end
  end

  test "a bundled structure is handed back in the shape the repository would have used" do
    structure = Soya::Bundled.fetch("DppLedLamp")

    assert_equal "DppLedLamp", structure.name
    assert JSON.parse(structure.jsonld).key?("@graph")
    assert structure.yaml.present?, "soya-form fetches the author's YAML while it renders"
  end

  test "a structure the image does not carry is answered with nothing, not with a guess" do
    assert_nil Soya::Bundled.fetch("SomethingElse")
    assert_not Soya::Bundled.include?("SomethingElse")
  end
end
