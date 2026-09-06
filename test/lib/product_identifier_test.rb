require "test_helper"

# The product identifier, checked against the identifiers that appear in the DPP
# Service's own documentation.
#
# These rules live in two repositories, which is how two codebases drift apart.
# The vectors are the defence: they are copied from the service's examples and
# from its ProductIdentifier, so a rule that changes over there shows up here as
# a failing test rather than as a rejected submission in front of an operator.
class ProductIdentifierTest < ActiveSupport::TestCase
  # From dpp-service/docs/examples-lightbulb.md and its ProductIdentifier.
  DIGITAL_LINK = "https://id.lumina.example/01/09520123456788".freeze

  test "a bare GTIN path is a model, and the path is what says so" do
    identifier = Dpp::ProductIdentifier.new(DIGITAL_LINK)

    assert identifier.valid?
    assert identifier.digital_link?
    assert_equal "model", identifier.granularity
  end

  test "a serial makes it one item, a batch number makes it a batch" do
    assert_equal "item",  granularity_of("#{DIGITAL_LINK}/21/000123")
    assert_equal "batch", granularity_of("#{DIGITAL_LINK}/10/L-2026-03")
    assert_equal "model", granularity_of("#{DIGITAL_LINK}/22/warm")
  end

  # A serial wins over a batch: an identifier that names both still names one
  # individual thing.
  test "a serial and a batch together are still one item" do
    assert_equal "item", granularity_of("#{DIGITAL_LINK}/10/L-2026-03/21/000123")
  end

  # The point of the self-issuing scheme: a domain the operator controls and
  # nothing else. Its path is opaque by design, so nothing can be derived from
  # it and the declaration is all there is.
  test "an identification link yields no granularity, because its path says nothing" do
    identifier = Dpp::ProductIdentifier.new("https://dpp.example.com/lamps/a60-827")

    assert identifier.valid?
    assert identifier.identification_link?
    assert_nil identifier.granularity
  end

  # Fifty characters is the whole budget, and it is spent on the host and the
  # serial. This is the one limit worth catching before a submission, because
  # the only remedies are a shorter host or a shorter serial — and both are
  # decisions, not corrections.
  test "the fifty character limit is reported with how far over it is" do
    identifier = Dpp::ProductIdentifier.new("https://much-too-long-hostname.example.org/01/09520123456788/21/000123")

    assert_equal :too_long, identifier.problem
    assert_equal identifier.value.length - 50, identifier.characters_over
  end

  test "a path that starts with an application identifier is judged as a Digital Link" do
    # Thirteen digits, not fourteen: the shorter GTIN spellings are refused
    # rather than padded, because padding in two codebases is how they diverge.
    identifier = Dpp::ProductIdentifier.new("https://id.example.com/01/0952012345678")

    assert identifier.digital_link?
    assert_equal :bad_digital_link, identifier.problem,
      "a malformed GTIN must not slip through by being read as free text"
  end

  test "the things that are not identifiers at all" do
    assert_equal :blank,     Dpp::ProductIdentifier.new("").problem
    assert_equal :not_https, Dpp::ProductIdentifier.new("http://id.example.com/01/09520123456788").problem
    assert_equal :not_a_url, Dpp::ProductIdentifier.new("id.example.com/01/09520123456788").problem
  end

  # A query string would carry GS1 data attributes rather than identity, and two
  # identifiers differing only in their query would collide in the custodian's
  # store. Data attributes belong in the document.
  # A short host on purpose: the checks run in the service's order, so length is
  # reported before shape, and DIGITAL_LINK plus a query is already over fifty.
  test "a query string or a fragment is refused" do
    short = "https://id.ex.com/01/09520123456788"

    assert_equal :has_query, Dpp::ProductIdentifier.new("#{short}?17=250101").problem
    assert_equal :has_query, Dpp::ProductIdentifier.new("#{short}#top").problem
  end

  test "every problem has a sentence in both languages" do
    problems = %i[blank not_a_url not_https too_long has_query bad_digital_link bad_path]

    %i[en de].each do |locale|
      I18n.with_locale(locale) do
        problems.each do |problem|
          message = I18n.t("passports.identifier.#{problem}", over: 4, length: 54, raise: true)
          assert message.present?, "#{locale}: #{problem} has no wording"
        end
      end
    end
  end

  private

  def granularity_of(value) = Dpp::ProductIdentifier.new(value).granularity
end
