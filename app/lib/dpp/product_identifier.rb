require "uri"

module Dpp
  # The uniqueProductIdentifier, checked here so the operator finds out while
  # they are typing rather than from a rejected submission.
  #
  # The authority is the DPP Service — app/services/product_identifier.rb there
  # is what actually decides, and anything this misses will be caught by it. So
  # why have it at all: because the one rule that trips people up is invisible
  # until it fails. The path of a GS1 Digital Link *expresses* the granularity,
  # and declaring a different one is refused. Deriving it here means the field
  # can be filled in for the operator instead of tested against them.
  #
  # This mirrors rules that live in another repository, which is how two
  # codebases drift apart. The defence is the test: it pins the identifiers out
  # of the service's own documentation, so a change over there shows up here as
  # a failure rather than as a rejection in front of an operator.
  #
  # Two schemes can be borne on a carrier as an https URL (EN 18219:2026 §5):
  #
  #   Digital Link         /01/<14-digit GTIN>[/10/<batch>][/21/<serial>][/22/<variant>]
  #                        the path says what granularity this is
  #   Identification link  the operator's own domain and a path they assign
  #                        opaque by design, so granularity has to be declared
  class ProductIdentifier
    # The EU DPP registry's limit, and the reason the whole identifier design is
    # tight: it is the string on the carrier, so its length is the budget.
    MAX_LENGTH = 50

    PRIMARY_AI = "01".freeze
    QUALIFIER_AIS = { "10" => "batch", "21" => "item", "22" => "model" }.freeze

    GTIN_PATTERN    = /\A\d{14}\z/
    AI_PATTERN      = /\A\d{2,4}\z/
    VALUE_PATTERN   = %r{\A[A-Za-z0-9\-_.]{1,20}\z}
    SEGMENT_PATTERN = %r{\A[A-Za-z0-9\-_.]{1,48}\z}

    GRANULARITIES = %w[model batch item].freeze

    attr_reader :value, :scheme, :qualifiers

    def initialize(value)
      @value = value.to_s.strip
      @uri = begin
        URI.parse(@value)
      rescue URI::InvalidURIError
        nil
      end
      @scheme = nil
      @qualifiers = nil
      @path = build_path
    end

    def digital_link? = scheme == :digital_link
    def identification_link? = scheme == :identification_link
    def valid? = problem.nil?

    # What the path says this identifier is about. nil for an identification
    # link, whose path is opaque on purpose — there the declaration is all there
    # is, and there is nothing to check it against.
    def granularity
      return nil unless digital_link?
      return "item"  if qualifiers.key?("21")
      return "batch" if qualifiers.key?("10")

      "model"
    end

    # A symbol naming what is wrong, or nil. Symbols rather than sentences so
    # the message can be in the operator's language and the reason stays one
    # thing — the translations carry the wording.
    def problem
      return :blank if value.empty?
      return :not_a_url if @uri.nil? || @uri.host.to_s.empty?
      return :not_https unless value.start_with?("https://")
      return :too_long if value.length > MAX_LENGTH
      return :has_query if @uri.query || @uri.fragment
      return (digital_link? ? :bad_digital_link : :bad_path) if @path.nil?

      nil
    end

    def characters_over = [ value.length - MAX_LENGTH, 0 ].max

    private

    def build_path
      path = @uri&.path.to_s.chomp("/")
      return nil if path.empty?

      segments = path.delete_prefix("/").split("/")
      return nil if segments.empty?

      # The first segment decides the scheme. A leading application identifier
      # means the Digital Link rules apply in full, so a malformed GTIN cannot
      # slip through by being read as free text.
      if AI_PATTERN.match?(segments.first.to_s)
        @scheme = :digital_link
        digital_link_path(segments, path)
      else
        @scheme = :identification_link
        segments.all? { |segment| SEGMENT_PATTERN.match?(segment) } ? path : nil
      end
    end

    def digital_link_path(segments, path)
      return nil unless segments.length.even? && segments.length >= 2

      pairs = segments.each_slice(2).to_a
      ai, gtin = pairs.first
      return nil unless ai == PRIMARY_AI && gtin.to_s.match?(GTIN_PATTERN)

      seen = { PRIMARY_AI => gtin }
      pairs.drop(1).each do |qualifier_ai, qualifier_value|
        return nil unless QUALIFIER_AIS.key?(qualifier_ai)
        return nil if seen.key?(qualifier_ai)
        return nil unless VALUE_PATTERN.match?(qualifier_value.to_s)

        seen[qualifier_ai] = qualifier_value
      end

      @qualifiers = seen
      path
    end
  end
end
