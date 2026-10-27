# One row, always id 1. Everything the application remembers about how it should
# behave, and where it should talk to.
class Setting < ApplicationRecord
  LOCALES = %w[en de].freeze

  # One custodian is offered by name, because "custodian" on its own is an empty
  # word: somebody meeting it for the first time reasonably wonders whether a
  # cloud drive would do. Naming a real data intermediary — one that already
  # runs the arrangement this application expects — turns the question from
  # "what is this" into "this one, or somebody else". Anyone else is a field.
  #
  # Its address goes into the service entry of every passport identifier minted
  # against it. It never reaches a data carrier, which bears the product
  # identifier under the operator's own host.
  KNOWN_CUSTODIAN = { name: "DID Daten-Intermediär-Dienste FlexCo",
                      base_url: "https://dpp.go-data.at" }.freeze

  def self.known_custodian?(base_url) = base_url.to_s == KNOWN_CUSTODIAN[:base_url]

  # The DPP Service of OwnYourData. Setup suggests it, the bar links to it until
  # another one is set up, and the footer always does: next to the service it
  # carries the Knowledge Base, the DPP Linter and the Validator.
  DEFAULT_SERVICE_BASE_URL = "https://dpp-service.ownyourdata.eu".freeze

  validates :locale, inclusion: { in: LOCALES }
  validates :idle_timeout_minutes, numericality: { greater_than_or_equal_to: 1, less_than_or_equal_to: 480 }

  def self.current
    first || create!(app_version: DppManager::VERSION)
  end

  def service_configured?
    service_base_url.present? && service_audience.present?
  end

  # A custodian is optional: without one the passports stay in the DPP Service's
  # own database. Both halves are needed together or not at all — a base URL
  # without a collection names a pod but no place in it.
  def custodian_configured?
    custodian_base_url.present? && custodian_collection_id.present?
  end

  def setup_complete? = setup_completed_at.present?

  # The service's list of authority issuers as last fetched, or nil when it was
  # never asked.
  def authority_issuers
    return nil if service_authority_issuers.blank?

    Array(JSON.parse(service_authority_issuers))
  rescue JSON::ParserError
    nil
  end

  def record_authority_issuers!(issuers)
    update!(service_authority_issuers: JSON.generate(Array(issuers)), service_authority_issuers_at: Time.current)
  end

  # How long the list of carrier hosts is taken as it is before the service is
  # asked again. It changes with the service's configuration, not with what is
  # done here, so a few minutes are plenty.
  CARRIER_HOSTS_FOR = 10.minutes

  # The hosts the service answers printed product identifiers on, as last
  # fetched; empty when it was never asked or names none.
  def carrier_hosts
    return [] if service_carrier_hosts.blank?

    Array(JSON.parse(service_carrier_hosts)).map(&:to_s)
  rescue JSON::ParserError
    []
  end

  def carrier_hosts_due?
    service_carrier_hosts_at.nil? || service_carrier_hosts_at <= Time.current - CARRIER_HOSTS_FOR
  end

  # +hosts+ nil means the service could not be asked: the list stays as it was,
  # and the attempt counts, so that a service out of reach costs one try per
  # interval rather than one per page.
  def record_carrier_hosts!(hosts)
    attributes = { service_carrier_hosts_at: Time.current }
    attributes[:service_carrier_hosts] = JSON.generate(Array(hosts)) unless hosts.nil?
    update!(attributes)
  end
end
