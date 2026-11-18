# What the operator of an installation can set from outside, through the
# environment, for an installation that is not on one person's own computer: on
# a server, behind a reverse proxy, as a shared test instance.
#
# Without any of these variables the application behaves exactly as it does on a
# laptop. Each one is read when it is needed, not once at boot, so a test can set
# it and take it away again.
module Deployment
  YES = %w[1 true yes on].freeze
  NO  = %w[0 false no off].freeze

  module_function

  # The DPP Service the setup suggests, and the bar links to until one is set up.
  # nil when the variable is not set or is not an http(s) address.
  def service_url
    value = ENV["DPP_SERVICE_URL"]
    return nil if value.blank?

    DppService::Directory.normalize_base(value)
  end

  # Ask search engines not to index any page: a meta element in every layout and
  # an X-Robots-Tag header on every response.
  def noindex? = flag?("DPP_NOINDEX")

  # Whether the setup offers the custodian it names. Only "off" (or "false",
  # "no", "0") turns it off; anything else, and nothing, leaves it on.
  def known_custodian_offered? = !NO.include?(ENV["DPP_KNOWN_CUSTODIAN"].to_s.strip.downcase)

  # Send the session cookie only over HTTPS. Off by default, because on one's
  # own computer the application is opened as http://localhost.
  def secure_cookies? = flag?("DPP_SECURE_COOKIES")

  def flag?(name) = YES.include?(ENV[name].to_s.strip.downcase)
end
