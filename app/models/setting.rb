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
end
