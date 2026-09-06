require "net/http"
require "uri"
require "json"

module Soya
  # Reading from a SOyA repository over HTTP.
  #
  # Three endpoints, all confirmed against soya.ownyourdata.eu rather than taken
  # from the specification, which is older than the tool in places:
  #
  #   GET /{name}                     the structure as JSON-LD
  #   GET /{name}/yaml                the author's version, if the repository has it
  #   GET /api/soya/query?name={part} [{"name":…,"dri":…}, …]
  #
  # This is the only place in the application that reaches the internet for a
  # structure. Everything afterwards works from the copy in the vault.
  module Repository
    # The JSON-LD context every SOyA structure points at. soya-js loads it with
    # its own HTTP client, straight out to the internet, bypassing whatever
    # repository it was configured with — so a structure kept for offline use
    # would still drag a network call behind it at the moment it is parsed.
    #
    # Hence inline_context!: the URL is replaced by the document it names, once,
    # while the network is there anyway. The result is semantically the same
    # JSON-LD and needs nothing outside the file.
    CONTEXT_URL = "https://ns.ownyourdata.eu/ns/soya-context.json".freeze

    DEFAULT_REPO = ENV.fetch("SOYA_REPO", "https://soya.ownyourdata.eu").freeze

    Structure = Struct.new(:name, :jsonld, :yaml, :dri, keyword_init: true)

    module_function

    def fetch(repo_base_url, name)
      base = Soya.normalize_base(repo_base_url) or raise Error, "invalid_repo_url"
      raise Error, "invalid_name" unless name.to_s.match?(ProductType::NAME)

      document = Http.get_json(URI.parse("#{base}/#{name}"))
      raise Error, "not_a_structure" unless document.is_a?(Hash) && document.key?("@graph")

      Structure.new(
        name:   name.to_s,
        jsonld: JSON.generate(inline_context(document)),
        yaml:   fetch_yaml(base, name),
        dri:    dri_for(base, name)
      )
    end

    # The author's YAML is a convenience, not a requirement: a structure pushed
    # as JSON-LD alone has none, and the repository answers 404. That is not a
    # failure of the fetch.
    def fetch_yaml(base, name)
      Http.body_as_text(Http.get(URI.parse("#{base}/#{name}/yaml"), accept: "text/plain"))
    rescue Error
      nil
    end

    # The query endpoint is the only one that reports a DRI for a name. Missing
    # it costs nothing, so a repository that does not offer the endpoint is not
    # an error either.
    def dri_for(base, name)
      results = Http.get_json(URI.parse("#{base}/api/soya/query?name=#{CGI.escape(name.to_s)}"))
      return nil unless results.is_a?(Array)

      results.find { |entry| entry["name"] == name.to_s }&.dig("dri")
    rescue Error
      nil
    end

    def search(repo_base_url, term)
      base = Soya.normalize_base(repo_base_url) or raise Error, "invalid_repo_url"
      results = Http.get_json(URI.parse("#{base}/api/soya/query?name=#{CGI.escape(term.to_s)}"))
      results.is_a?(Array) ? results : []
    end

    # Replaces the reference to the shared context with the context itself.
    #
    # A structure from the repository does not carry the context as a plain URL,
    # which is what one expects and what does not happen. It carries an object:
    #
    #   "@context": { "xsd": …, "@base": …, "@import": "https://ns…/soya-context.json" }
    #
    # JSON-LD 1.1 @import means "start from that context, then apply mine on
    # top", so resolving it is a merge in exactly that order — the structure's
    # own keys win, which is what @import specifies and also what @base needs.
    #
    # Both shapes are handled: the object with @import, and a bare URL, in case
    # a repository ever publishes the simpler form.
    def inline_context(document)
      context = resolve_context(document["@context"])
      return document if context.nil?

      document.merge("@context" => context)
    end

    def resolve_context(value)
      case value
      when String
        value == CONTEXT_URL ? context_document : nil
      when Array
        return nil unless value.any? { |entry| entry == CONTEXT_URL }
        imported = context_document or return nil
        value.map { |entry| entry == CONTEXT_URL ? imported : entry }
      when Hash
        return nil unless value["@import"] == CONTEXT_URL
        imported = context_document or return nil
        imported.merge(value.except("@import"))
      end
    end

    # The context document as a plain term map. The file is a JSON-LD context,
    # so the terms sit under "@context"; a repository that serves the map
    # directly is accepted too rather than producing a context nested in itself.
    def context_document
      @context_document ||= begin
        document = Http.get_json(URI.parse(CONTEXT_URL))
        terms = document.is_a?(Hash) && document["@context"].is_a?(Hash) ? document["@context"] : document
        terms.is_a?(Hash) ? terms : nil
      end
    rescue Error
      # Without it the structure keeps the reference and still works — as long
      # as there is a network at the moment a form is generated. Worth
      # continuing for; not worth failing the fetch over.
      nil
    end
  end
end
