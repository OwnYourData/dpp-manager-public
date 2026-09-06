require "test_helper"

# Net::HTTP hands back every body tagged ASCII-8BIT, whatever the response said.
# That is invisible until the first non-ASCII byte, and then it surfaces as an
# Encoding::UndefinedConversionError while saving or rendering — nowhere near
# the fetch, and naming a byte rather than a file. A German label in a
# structure's YAML is enough to trigger it.
class SoyaHttpTest < ActiveSupport::TestCase
  test "a utf-8 body arrives as text even though the socket calls it binary" do
    body = "label: Umlaute — Größe".dup.force_encoding("ASCII-8BIT")

    text = Soya::Http.body_as_text(fake(body, "text/plain; charset=utf-8"))
    assert_equal Encoding::UTF_8, text.encoding
    assert_equal "label: Umlaute — Größe", text
  end

  test "a body with no charset is read as utf-8 rather than left binary" do
    text = Soya::Http.body_as_text(fake("Größe".dup.force_encoding("ASCII-8BIT"), "text/plain"))
    assert_equal "Größe", text
  end

  test "a body that names a charset it is not in loses the bad bytes, not the structure" do
    text = Soya::Http.body_as_text(fake("ok \xFF here".dup.force_encoding("ASCII-8BIT"), "text/plain; charset=utf-8"))

    assert text.valid_encoding?
    assert_match "ok", text
    assert_match "here", text
  end

  test "json is parsed from the decoded text, so a german label survives" do
    response = fake({ label: "Größe" }.to_json.dup.force_encoding("ASCII-8BIT"), "application/json")
    assert_equal "Größe", Soya::Http.parse(response)["label"]
  end

  private

  # Net::HTTPResponse is awkward to build; what body_as_text uses is the body
  # and the content type, and those are what this stands in for.
  def fake(body, content_type)
    Struct.new(:body, :type_params).new(body, parse_type_params(content_type))
  end

  def parse_type_params(content_type)
    content_type.split(";").drop(1).to_h { |part| part.strip.split("=", 2) }
  end
end
