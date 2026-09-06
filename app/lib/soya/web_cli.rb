require "uri"
require "json"

module Soya
  # The soya-web-cli process running beside Rails in this container.
  #
  # It is soya-js behind an HTTP interface — the same code as the `soya` command
  # line tool, which is what makes it worth carrying a second runtime: the form
  # a structure produces here is the form it produces everywhere else, rather
  # than one this application derived from the same overlays and got subtly
  # different.
  #
  #   GET  /api/v1/form/{name}?language=&tag=   {"schema":…, "ui":…, "options":…}
  #   POST /api/v1/validate/{name}              SHACL result
  #   POST /api/v1/transform/{name}             the jq overlay, applied
  #   POST /api/v1/acquire/{name}               flat JSON to JSON-LD
  #   GET  /api/v1/version                      also reports the repository it uses
  #
  # Every one of those resolves the structure by pulling it from the repository
  # it was configured with — and that repository is this application (see
  # Soya::RepositoryController). So none of them reaches the internet, and all
  # of them work from the vault.
  module WebCli
    BASE = ENV.fetch("SOYA_WEB_CLI_URL", "http://127.0.0.1:8081").freeze

    # Generating a form parses the whole structure; a large one on a laptop that
    # is also running everything else is not instant.
    TIMEOUT = ENV.fetch("SOYA_WEB_CLI_TIMEOUT", 60).to_i

    module_function

    def available?
      version.present?
    rescue Error
      false
    end

    def version
      Http.get_json(url("version"), timeout: 5)
    end

    def form(name, language: nil, tag: nil)
      query = { language: language, tag: tag }.compact.map { |k, v| "#{k}=#{CGI.escape(v.to_s)}" }.join("&")
      path  = "form/#{CGI.escape(name.to_s)}"
      path += "?#{query}" if query.present?

      result = Http.get_json(url(path), timeout: TIMEOUT)
      raise Error, "no_form" unless result.is_a?(Hash) && result["schema"].present?

      result
    end

    def validate(name, data)
      Http.parse(Http.post_json(url("validate/#{CGI.escape(name.to_s)}"), data, timeout: TIMEOUT))
    end

    def transform(name, data)
      Http.parse(Http.post_json(url("transform/#{CGI.escape(name.to_s)}"), data, timeout: TIMEOUT))
    end

    def acquire(name, data)
      Http.parse(Http.post_json(url("acquire/#{CGI.escape(name.to_s)}"), data, timeout: TIMEOUT))
    end

    def url(path)
      URI.parse("#{BASE}/api/v1/#{path}")
    end
  end
end
