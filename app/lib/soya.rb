require "uri"

# Everything that talks to SOyA, in two halves.
#
# Soya::Repository reaches a SOyA repository over the internet, once, when the
# operator adds or refreshes a product type. Soya::WebCli talks to the
# soya-web-cli process inside this container, which does the work the command
# line tool does — generate a form, validate, transform, acquire — and which is
# pointed back at this application rather than at the internet. Between them,
# the only moment that needs a network is the fetch.
module Soya
  module_function

  # Shared by both: a base URL the way this application wants to store it —
  # scheme present, no trailing slash, nothing else changed.
  def normalize_base(value)
    raw = value.to_s.strip.chomp("/")
    return nil if raw.empty?

    # A bare host is completed to https. Anything that already names a scheme
    # keeps it and is judged on it — prefixing "ftp://soya.example" would
    # produce "https://ftp://soya.example", which parses, has the host "ftp",
    # and is accepted as a perfectly good address to nowhere.
    return nil if raw.include?("://") && !raw.match?(%r{\Ahttps?://}i)

    raw = "https://#{raw}" unless raw.match?(%r{\Ahttps?://}i)
    uri = URI.parse(raw)
    return nil unless uri.is_a?(URI::HTTP) && uri.host.present?

    uri.to_s.chomp("/")
  rescue URI::InvalidURIError
    nil
  end
end
